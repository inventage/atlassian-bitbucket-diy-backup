# Bitbucket Server DIY Backup #

This repository contains a set of example scripts that demonstrate best practices for backing up a Bitbucket Server/Data
Center instance using a curated set of vendor technologies.

The scripts contained within this repository enable two categories of backup:

* Backups with downtime. This is the only type of backup available if your Bitbucket instance is older than 4.8 or if
  you are using the ``rsync`` strategy (described below)
* Zero downtime backups. To enable Zero Downtime Backup, you will need to set the variable `BACKUP_ZERO_DOWNTIME` to
  `true`. If true, this variable will backup the filesystem and database **without** locking the application.
  **NOTE:** This is only available from version 4.8 of Bitbucket Server/Data Center, and requires a compatible strategy
  for taking atomic block level snapshots of the home directory.

These scripts have been changed significantly with the release of Bitbucket 6.0. If updating from an older version of
the scripts, a number of configured variables will need updating. See the **Updating** section below for a list of
considerations when updating to a newer version of the backup scripts.

### Strategies ###

In order to use these example scripts you must specify a `BACKUP_DISK_TYPE` and `BACKUP_DATABASE_TYPE` strategy, and
optionally a `BACKUP_ARCHIVE_TYPE` and/or `BACKUP_ELASTICSEARCH_TYPE` strategy. These strategies can be set within the
`bitbucket.diy-backup.vars.sh`.

For each `BACKUP_DISK_TYPE`, `BACKUP_DATABASE_TYPE`, `BACKUP_ARCHIVE_TYPE` and `BACKUP_ELASTICSEARCH_TYPE` strategy,
additional variables need to be set in `bitbucket.diy-backup.vars.sh` to configure the details of your Bitbucket 
instance's home directory, database, and other options. Refer to `bitbucket.diy-backup.vars.sh.example` for a complete 
description of all the various variables and their definitions.

`BACKUP_DISK_TYPE` Strategy for backing up the Bitbucket home directory and any configured data stores, valid values are:

* `amazon-ebs`          - Amazon EBS snapshots of the volume(s) containing the home directory and data stores.
* `rsync`               - "rsync" of the home directory and data store contents to a temporary location. **NOTE:** This
                          can NOT be used with `BACKUP_ZERO_DOWNTIME=true`.
* `zfs`                 - ZFS snapshot strategy for home directory and data store backups.

`BACKUP_DATABASE_TYPE` Strategy for backing up the database, valid values are:

* `amazon-rds`          - Amazon RDS snapshots.
* `mysql`               - MySQL using "mysqldump" to backup and "mysql" to restore.
* `postgresql`          - PostgreSQL using "pg_dump" to backup and "pg_restore" to restore.
* `postgresql-fslevel`  - PostgreSQL with data directory located in the file system volume as home directory (so that
                           it will be included implicitly in the home volume snapshot).

`BACKUP_ARCHIVE_TYPE`  Strategy for archiving backups and/or copying them to an offsite location, valid values are:

* `<leave-blank>`       - Do not use an archiving strategy.
* `aws-snapshots`       - AWS EBS and/or RDS snapshots, with optional copy to another region.
* `gpg-zip`             - "gpg-zip" archive
* `tar`                 - Unix "tar" archive


`BACKUP_ELASTICSEARCH_TYPE` Strategy for backing up Elasticsearch, valid values are:

* `<leave blank>`       - No separate snapshot and restore of Elasticsearch state (default).
                        - recommended for Bitbucket Server instances configured to use the (default) bundled 
                          Elasticsearch instance. In this case all Elasticsearch state is stored under 
                          ${BITBUCKET_HOME}/shared and therefore already included in the home directory snapshot 
                          implicitly. NOTE: If Bitbucket is configured to use a remote Elasticsearch instance (which 
                          all Bitbucket Data Center instances must be), then its state is NOT included implictly in 
                          home directory backups, and may therefore take some to rebuild after a restore UNLESS one of
                          the following strategies is used.
* `amazon-es`           - Amazon Elasticsearch Service - uses an S3 bucket as a snapshot repository. Requires both 
                          python and the python package 'boto' to be installed in order to sign the requests to AWS ES.
                          Once python has been installed run 'sudo pip install boto' to install the python boto package.
* `s3`                  - Amazon S3 bucket - requires the Elasticsearch Cloud plugin to be installed. See 
                          https://www.elastic.co/guide/en/elasticsearch/plugins/2.3/cloud-aws.html
* `fs`                  - Shared filesystem - requires all data and master nodes to mount a shared file system to the 
                          same mount point and that it is configured in the elasticsearch.yml file. See 
                          https://www.elastic.co/guide/en/elasticsearch/reference/current/modules-snapshots.html

`STANDBY_DISK_TYPE` Strategy for Bitbucket home directory disaster recovery, valid values are:
*  `zfs`                - ZFS snapshot strategy for disk replication.

`STANDBY_DATABASE_TYPE` Strategy for replicating the database, valid values are:
*  `amazon-rds`         - Amazon RDS Read replica
*  `postgresql`         - PostgreSQL replication

### Configuration ####

You will need to configure the script variables found in `bitbucket.diy-backup.vars.sh` based on your chosen strategies.
**Note** that not all options need to be configured. The backup strategy you choose together with your vendor tools will
determine which options should be set. See `bitbucket.diy-backup.vars.sh.example` for a complete set of all 
configuration options.

`BACKUP_ZERO_DOWNTIME` If set to true, the home directory and database will be backed up **without** locking Bitbucket
by placing it in maintenance mode. **NOTE:** This can NOT be used with Bitbucket Server versions older than 4.8. For 
more information, see [Zero downtime backup](https://confluence.atlassian.com/display/BitbucketServer/Using+Bitbucket+Zero+Downtime+Backup).
Make sure you read and understand this document before uncommenting this variable.

### Upgrading ###
In order to support Bitbucket Server 6.0, significant changes have been made to these scripts. If moving from an older 
version of the DIY scripts, you will need to change certain variables in the `bitbucket.diy-backup.vars.sh` file. These
changes have been noted in `bitbucket.diy-backup.vars.sh.example`.
* `BACKUP_HOME_TYPE` has been renamed to `BACKUP_DISK_TYPE`
* `STANDBY_HOME_TYPE` has been renamed to `STANDBY_DISK_TYPE`

####`amazon-ebs` strategy ####
* A new `EBS_VOLUME_MOUNT_POINT_AND_DEVICE_NAMES` variable has been introduced, which is an array of all EBS volumes 
  (the shared home directory, and any configured data stores). It needs to contain the details for the shared home that
  were previously stored in `HOME_DIRECTORY_MOUNT_POINT` and `HOME_DIRECTORY_DEVICE_NAME`.
* The `HOME_DIRECTORY_DEVICE_NAME` variable is no longer needed.
* The `HOME_DIRECTORY_MOUNT_POINT` variable should still be set.
* `RESTORE_HOME_DIRECTORY_VOLUME_TYPE` has been renamed to `RESTORE_DISK_VOLUME_TYPE`.
* `RESTORE_HOME_DIRECTORY_IOPS` has been renamed to `RESTORE_DISK_IOPS`.
* `ZFS_HOME_TANK_NAME` has been replaced with `ZFS_FILESYSTEM_NAMES`, an array containing filesystem names for the 
  shared home, as well as any data stores. This is only required if `FILESYSTEM_TYPE` is set to `zfs`.

**Note:** EBS snapshots are now tagged with the device name they are a snapshot of. If snapshots were taken previously, 
they will not have this tag, and as a result:
* Old ebs snapshots without a "Device" tag won't be cleaned up automatically
* Restoring from an old ebs snapshot without a "Device" tag will fail

Both of these issues can be mitigated by adding the "Device" tag manually in the AWS console. For any EBS snapshots,
add a tag with "Device" as the key and `"<device_name>"` as the value, where `<device_name>` is the device name of the 
EBS volume holding the shared home directory (e.g. `"Device" : "/dev/xvdf"`).

#### `rsync` strategy ####
* If any data stores are configured on the instance, `BITBUCKET_DATA_STORES` should be specified as an array of paths to
  data stores.
* If any data stores are configured on the instance, `BITBUCKET_BACKUP_DATA_STORES` should specify a location for
  for storing data store backups. 

#### `zfs` strategy ####
* A new `ZFS_FILESYSTEM_NAMES` variable has been introduced, which is an array of ZFS filesystems (the shared home 
  directory, and any configured data stores). It needs to contain the filesystem name of the shared home directory,
  which was previously stored in `ZFS_HOME_TANK_NAME`.
* If using these scripts for disaster recovery, a new variable `ZFS_HOME_FILESYSTEM` needs to be set. This should
  contain the name of the ZFS filesystem storing the shared home directory - the same value that was previously stored
  in `ZFS_HOME_TANK_NAME`.

### Bugs and Suggestions ###

Please report any bugs through [normal support channels](https://support.atlassian.com/servicedesk/customer/portal/24).

Report suggestions in the [Bitbucket Server issue tracker](https://jira.atlassian.com/browse/BSERV).

Please note that DIY Backup is intended as a jumping off point for your to create your _own_ back up strategy, and we 
don't intend to create a solution for all potential configurations of Bitbucket Server.

### Further reading ###
* [Zero Downtime Backup](https://confluence.atlassian.com/display/BitbucketServer/Using+Bitbucket+Zero+Downtime+Backup)
* [Using Bitbucket Server DIY Backup](https://confluence.atlassian.com/display/BitbucketServer/Using+Bitbucket+Server+DIY+Backup)
* [Using Bitbucket Server DIY Backup in AWS](https://confluence.atlassian.com/display/BitbucketServer/Using+Bitbucket+Server+DIY+Backup+in+AWS)