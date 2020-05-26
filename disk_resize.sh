#!/bin/sh

#####################################################################################################################################
## SCRIPT NAME: disk_resize.sh                                                                                                     ##
## PURPOSE    : To resize EBS volumes whenever space used in the Diskgroup crosses above threshold                                 ##
## USAGE      : disk_resize.sh                                                                                                     ##
## Script Logic:                                                                                                                   ##
## > Identify diskgroups where used_space is beyond threshold                                                                      ##
## > Identify device name, EBS volume id and current disk size for disks belonging to diskgroup, that has to be resized.           ##
## > For every disk identified, perform below steps:                                                                               ##
##     * Find major & minor# of asm disk                                                                                           ##
##     * Find matching device (/dev/nvme*)                                                                                         ##
##     * Identify EBS Volume ID of the device which will be used in AWS CLI for Volume resize                                      ##
##     * Wait for resize operation to complete                                                                                     ##
##     * Update Filesystem partition to reflect new disk size                                                                      ##
##     * Update Diskgroup to reflect new size                                                                                      ##
## > After DiskGroup resize, identify tablespaces that are below threshold.                                                        ##
##     * For SmallFile Tablespace, add datafile of size 32 Gb                                                                      ##
##     * For BigFile Tablespace, extend the MaxSize of the tablespace                                                              ##
##                                                                                                                                 ##
## SCRIPT HISTORY:                                                                                                                 ##
## 05/12/2020  Jeevan Shetty        Initial Copy                                                                                   ##
##                                                                                                                                 ##
#####################################################################################################################################

SCRIPT=$0
v_dg_used_percent=70
v_dg_growth_percent=20
v_tbs_used_percent=70
v_tbs_growth_percent=20

v_loop_cnt=10
v_sleep_cnt=2
v_log='/tmp/disk_resize.log'
v_dg_lst='/tmp/disk_list.log'
v_asm_disk_loc='/dev/oracleasm/disks'

echo "`date` : Script - $SCRIPT Started" >$v_log

export DB_NAME="TCICT"
export ORACLE_SID="+ASM"
export ORAENV_ASK=NO
export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin:/root/bin

. /usr/local/bin/oraenv >/dev/null

#
# Setting 64 bit libraries used by aws/python
#
export LD_LIBRARY_PATH=/usr/lib64:$LD_LIBRARY_PATH

#
# Identify diskgroups that do not have enough space. This query will output the current state of diskgroups
#
echo "`date` : Identifying diskgroups that do not have enough space" >>$v_log
sqlplus -s "/as sysasm" <<EOF1 >>$v_log 2>&1

    set lines 200 pages 2000
    col DISK_FILE_PATH format a40

    select a.name disk_group_name, b.name disk_file_name, b.path disk_file_path, b.label disk_name, a.TOTAL_MB, a.FREE_MB, round(a.free_mb/a.total_mb*100) percent_free
      from v\$asm_diskgroup a, v\$asm_disk b
     where a.GROUP_NUMBER = b.GROUP_NUMBER
       and 100-round(a.free_mb/a.total_mb*100) >= $v_dg_used_percent
     order by 2;

    exit;
EOF1

#
# Similar to above query but we identify the disk name which is saved to file $v_log. Also, it identifies the volume increment size for individual disks when the diskgroup size is above
# v_dg_used_percent threshold
#
sqlplus -s "/as sysasm" <<EOF2 >$v_dg_lst
    set term off head off lines 120 pages 2000 feedback off
    col disk_group_name format a30
    col disk_name format a30

    select a.name disk_group_name, b.label disk_name, ceil(($v_dg_growth_percent/100*a.total_mb)/1024/c.disk_cnt) vol_size_incr
      from v\$asm_diskgroup a, v\$asm_disk b, (select group_number, count(*) disk_cnt from v\$asm_disk group by group_number) c
     where a.GROUP_NUMBER = b.GROUP_NUMBER
       and a.GROUP_NUMBER = c.GROUP_NUMBER
       and 100-round(a.free_mb/a.total_mb*100) >= $v_dg_used_percent;

    exit;
EOF2

#
# For every disk identified in above query, identify device name, EBS volume id and current disk size. These EBS volumes will be resized by increments defined in variable - v_vol_size_incr
#
cat $v_dg_lst | grep -v "no rows selected" | grep -v "^ *$" | while read v_disk_group_name v_disk_name v_vol_size_incr
do

    #
    # The major & minor# of asm disk under /dev/oracleasm/disks and disks under /dev/ match. This is used to identify the device name.
    # The device name will be used to identify the EBS volume id and current size, which will be eventually resized to v_new_vol_size.
    #
    v_major_minor_num=`ls -l $v_asm_disk_loc/$v_disk_name | tr -s ' ' | awk '{print $5,$6}'`
    # echo "`date` : major_minor_num = ($v_major_minor_num) for disk = $v_asm_disk_loc/$v_disk_name" >>$v_log 2>&1

    #
    # This provides sub-partition name of the device
    #
    v_device=`ls -l /dev/nvme* | tr -s ' ' | grep -w "$v_major_minor_num" | cut -f 10 -d ' '`
    v_vol_id=`sudo nvme id-ctrl -v "$v_device" | grep "^sn" | cut -f 2 -d ':' | sed 's/ vol/vol-/'`

    #
    # Identify main partition name of the device which will be used to reformat the device
    #
    v_device=`sudo nvme list | tr -s ' ' | grep $(echo "$v_vol_id" | sed 's/vol-/vol/') | cut -f 1 -d ' '`
    v_vol_size=`aws ec2 describe-volumes --region us-west-2 --volume-id $v_vol_id --query "Volumes[0].{SIZE:Size}" 2>>$v_log | grep "SIZE" | tr -s ' ' | cut -f 3 -d ' '`
    v_new_vol_size=`expr $v_vol_size + $v_vol_size_incr`

    echo "`date` : Resizing Disk Group = $v_disk_group_name, Disk = $v_disk_name, Device Name = $v_device, Volume = $v_vol_id, Current Size = $v_vol_size, New Size = $v_new_vol_size" >>$v_log
    echo "`date` : aws ec2 modify-volume --region us-west-2 --volume-id $v_vol_id --size $v_new_vol_size" >>$v_log 2>&1
    # aws ec2 modify-volume --region us-west-2 --volume-id $v_vol_id --size $v_new_vol_size >>$v_log 2>&1

    if [[ $? -ne 0 ]]
    then
        echo "`date` : ERROR in Volume Resize !!!" >>$v_log
    else

        #
        # Check the status of resize operation and wait till the modification is complete
        #
        v_state=`aws ec2 describe-volumes-modifications --region us-west-2 --volume-id $v_vol_id  --query "VolumesModifications[0].{ModificationState:ModificationState}" 2>>$v_log | grep "State" | cut -f 4 -d '"'`
        echo "`date` : Volume Modification State = $v_state ..." >>$v_log

        v_cnt=$v_loop_cnt
        while [[ $v_state == "modifying" ]]
        do
            if [[ $v_cnt -gt 0 ]]
            then
                v_cnt=`expr $v_cnt - 1`
                sleep $v_sleep_cnt
                v_state=`aws ec2 describe-volumes-modifications --region us-west-2 --volume-id $v_vol_id  --query "VolumesModifications[0].{ModificationState:ModificationState}" 2>>$v_log | grep "State" | cut -f 4 -d '"'`
                echo "`date` : Volume Modification State = $v_state ..." >>$v_log
            else
                echo "`date` : ERROR Volume - $v_vol_id resize is taking more than $v_loop_cnt * $v_sleep_cnt seconds !!!" >>$v_log
                exit
            fi

        done


        #
        # After the EBS Volume has been resized, the partition of the disk has to be reconfigured to reflect the new size
        # Please do not modify/delete the blank lines below. Those are the inputs for the disk resize
        #
        sudo fdisk $v_device <<EOF >/dev/null 2>&1
d
n




w
EOF

        sudo partx -u $v_device

        #
        # After disk resize, alter the diskgroup and check the new size in the output
        #
        echo "`date` : Size of diskgroups after volume resize." >>$v_log
        sqlplus -s "/as sysasm" <<EOF3 >>$v_log

            set lines 200 pages 2000
            col DISK_FILE_PATH format a40

            alter diskgroup $v_disk_group_name resize all;

            select a.name disk_group_name, b.name disk_file_name, b.path disk_file_path, b.label disk_name, a.TOTAL_MB, a.FREE_MB, round(a.free_mb/a.total_mb*100) percent_free
              from v\$asm_diskgroup a , v\$asm_disk b
             where a.GROUP_NUMBER = b.GROUP_NUMBER
            -- and round(a.free_mb/a.total_mb*100) >= $v_dg_used_percent
             order by 2;


            exit;
EOF3

    fi


done

export ORACLE_SID=$DB_NAME

. /usr/local/bin/oraenv >/dev/null

sqlplus -s "/as sysdba" <<EOF4 >$v_dg_lst 2>>$v_log
    set term off head off lines 120 pages 2000 feedback off
    col disk_name format a30

    with sql_stat_query as
         (select case
                 when bigfile='YES' and round((bytes-free_bytes)/extensible_max_bytes,2)*100 > $v_tbs_used_percent
                 then
                      'alter tablespace '||dt.tablespace_name||' autoextend on maxsize '||round((1+$v_tbs_growth_percent/100)*extensible_max_bytes/1024/1024)||'M;'
                 when bigfile!='YES' and 100 - round((extensible_free_bytes+free_bytes)/(smallfile_bytes+extensible_max_bytes),2)*100 > $v_tbs_used_percent
                 then
                      'alter tablespace '||dt.tablespace_name||' add datafile size 32G autoextend off;'
                 end sql_statement
            from dba_tablespaces dt,
                 (select tablespace_name, sum(bytes) bytes, sum(decode(maxbytes,0,bytes,0)) smallfile_bytes, sum(maxbytes) extensible_max_bytes,
                         sum(decode(maxbytes,0,0,maxbytes-bytes)) extensible_free_bytes from dba_data_files group by tablespace_name) db,
                 (select tablespace_name, sum(bytes) free_bytes from dba_free_space group by tablespace_name) df
           where dt.tablespace_name=db.tablespace_name
             and df.tablespace_name=db.tablespace_name)
    select * from sql_stat_query where sql_statement is not null;

    exit;
EOF4

cat $v_dg_lst | grep -v "no rows selected" | grep -v "^ *$" | while read v_sql_statement
do
    echo "`date` : $v_sql_statement" >>$v_log
done

v_error_cnt=`grep -i error $v_log | grep -v grep | wc -l`

if [[ $v_error_cnt -gt 0 ]]
then
    # Mail yet to be enabled in AWS EC2 instances

    echo "`date` : Mail Sent !!!" >>$v_log

fi

echo "`date` : Script - $SCRIPT Completed" >>$v_log
echo "`date` : " >>$v_log
echo "`date` : " >>$v_log

cat $v_log


