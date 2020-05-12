#!/bin/sh


SCRIPT=$0
v_used_percent=13
v_dg_growth_percent=10
v_log='/tmp/disk_resize.log'
v_dg_lst='/tmp/disk_list.log'
v_asm_disk_loc='/dev/oracleasm/disks'

echo "`date` : Script - $SCRIPT Started" >$v_log

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
sqlplus -s "/as sysasm" <<EOF1 >>$v_log

    set lines 200 pages 2000
    col DISK_FILE_PATH format a40

    select a.name disk_group_name, b.name disk_file_name, b.path disk_file_path, b.label disk_name, a.TOTAL_MB, a.FREE_MB, round(a.free_mb/a.total_mb*100) percent_free
      from v\$asm_diskgroup a , v\$asm_disk b
     where a.GROUP_NUMBER = b.GROUP_NUMBER
       and round(a.free_mb/a.total_mb*100) >= $v_used_percent
     order by 2;

    exit;
EOF1

#
# Similar to above query but we identify the disk name which is saved to file $v_log. Also, it identifies the volume increment size for individual disks when the diskgroup size is above
# v_used_percent threshold
#
sqlplus -s "/as sysasm" <<EOF2 >$v_dg_lst
    set term off head off lines 120 pages 2000
    col disk_group_name format a30
    col disk_name format a30

    select a.name disk_group_name, b.label disk_name, ceil(($v_dg_growth_percent/100*a.total_mb)/1024/c.disk_cnt) vol_size_incr
      from v\$asm_diskgroup a , v\$asm_disk b, (select group_number, count(*) disk_cnt from v\$asm_disk group by group_number) c
     where a.GROUP_NUMBER = b.GROUP_NUMBER
       and a.GROUP_NUMBER = c.GROUP_NUMBER
       and round(a.free_mb/a.total_mb*100) >= $v_used_percent;

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

    #
    # This provides sub-partition name of the device
    #
    v_device=`ls -l /dev/* | tr -s ' ' | grep "$v_major_minor_num" | cut -f 10 -d ' '`
    v_vol_id=`sudo nvme id-ctrl -v "$v_device" | grep "^sn" | cut -f 2 -d ':' | sed 's/ vol/vol-/'`

    #
    # Identify main partition name of the device which will be used to reformat the device
    #
    v_device=`sudo nvme list | tr -s ' ' | grep $(echo "$v_vol_id" | sed 's/vol-/vol/') | cut -f 1 -d ' '`
    v_vol_size=`aws ec2 describe-volumes --region us-west-2 --volume-id $v_vol_id --query "Volumes[0].{SIZE:Size}" | grep "SIZE" | tr -s ' ' | cut -f 3 -d ' '`
    v_new_vol_size=`expr $v_vol_size + $v_vol_size_incr`

    echo "`date` : Resizing Disk Group = $v_disk_group_name, Disk = $v_disk_name, Device Name = $v_device, Volume = $v_vol_id, Current Size = $v_vol_size, New Size = $v_new_vol_size" >>$v_log

    aws ec2 modify-volume --region us-west-2 --volume-id $v_vol_id --size $v_new_vol_size >>$v_log 2>&1

    if [[ $? -ne 0 ]]
    then
    echo "`date` : ERROR in Volume Resize !!!" >>$v_log
    else

        #
        # Check the status of resize operation and wait till the modification is complete
        #
        v_state=`aws ec2 describe-volumes-modifications --region us-west-2 --volume-id $v_vol_id  --query "VolumesModifications[0].{ModificationState:ModificationState}" | grep "State" | cut -f 4 -d '"'`
        echo "`date` : $v_state ..." >>$v_log

        while [[ $v_state == "modifying" ]]
        do
            sleep 2
            v_state=`aws ec2 describe-volumes-modifications --region us-west-2 --volume-id $v_vol_id  --query "VolumesModifications[0].{ModificationState:ModificationState}" | grep "State" | cut -f 4 -d '"'`
            echo "`date` : $v_state ..." >>$v_log
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
            -- and round(a.free_mb/a.total_mb*100) >= $v_used_percent
             order by 2;


            exit;
EOF3

    fi


done


v_error_cnt=`grep -i error $v_log | grep -v grep | wc -l`

if [[ $v_error_cnt -gt 0 ]]
then
    echo "`date` : Mail Sent !!!" >>$v_log

fi

echo "`date` : Script - $SCRIPT Completed" >>$v_log
echo "`date` : " >>$v_log
echo "`date` : " >>$v_log

cat $v_log

