# disk_resize
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
#####################################################################################################################################
