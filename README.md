# Bitbucket Server DIY Backup #

This repository contains a set of example scripts that demonstrate best practices for backing up a Bitbucket Server/Data Center instance using a curated set of vendor technologies.

The scripts contained within this repository enable two categories of backup

* Backups with downtime. This is the only type of backup available if your Bitbucket instance is older than 4.8 or if you
are using the ``rsync`` strategy (described below)
* Zero downtime backups. To enable Zero Downtime Backup, you will need to set the variable `BACKUP_ZERO_DOWNTIME` to `true`.
If true, this variable will backup the filesystem and database **without** locking the application. **NOTE:** This is
only available from version 4.8 of Bitbucket Server/Data Center, and requires a compatible strategy for taking atomic
block level snapshots of the home directory.

### Configuration ####

The following is a list of configuration options that should be set in `bitbucket.diy-backup.vars.sh`. **Note** that not
 all options need to be configured. The backup strategy you choose together with your vendor tools will determine
 which options should be set. See `bitbucket.diy-backup.vars.sh.example` for a complete set of all configuration options

`INSTANCE_NAME` Name used to identify the Bitbucket instance being backed up. This appears in archive names and AWS
snapshot tags. It should not contain spaces and must be under 100 characters long.

`BITBUCKET_URL` The base URL of the Bitbucket instance to be backed up. It cannot end on a '/'.

`BITBUCKET_HOME` The path to the Bitbucket home directory (with trailing /).

`BITBUCKET_UID` and `BITBUCKET_GID` Owner and group of `${BITBUCKET_HOME}`.

`BACKUP_HOME_TYPE` Strategy for backing up the Bitbucket home directory, valid values are:

* `amazon-ebs`          - Amazon EBS snapshots of the volume containing the home directory.
* `rsync`               - "rsync" of the home directory contents to a temporary location. **NOTE:** This can NOT be used
                           with `BACKUP_ZERO_DOWNTIME=true`.

`BACKUP_DATABASE_TYPE` Strategy for backing up the database, valid values are:

* `amazon-rds`           - Amazon RDS snapshots.
* `mysql`                - MySQL using "mysqldump" to backup and "mysql" to restore.
* `postgresql`           - PostgreSQL using "pg_dump" to backup and "pg_restore" to restore.
* `postgresql93-fslevel` - PostgreSQL 9.3 with data directory located in the file system volume as home directory (so
                            that it will be included implicitly in the home volume snapshot).

`BACKUP_ARCHIVE_TYPE`  Strategy for archiving backups and/or copying them to an offsite location, valid values are:

* `aws-snapshots`        - AWS EBS and/or RDS snapshots, with optional copy to another region.
* `gpg-zip`              - "gpg-zip" archive
* `tar`                  - Unix "tar" archive

`BACKUP_ZERO_DOWNTIME` If set to true, the home directory and database will be backed up **without** locking Bitbucket
by placing it in maintenance mode. **NOTE:** This can NOT be used with Bitbucket Server versions older than 4.8. For
more information, see [Zero downtime backup](https://confluence.atlassian.com/display/BitbucketServer/Using+Bitbucket+Zero+Downtime+Backup).
Make sure you read and understand this document before uncommenting this variable.

`BITBUCKET_BACKUP_USER` and `BITBUCKET_BACKUP_PASS` The username and password to a user with the necessary permissions
required to lock Bitbucket in maintenance mode. Only required when `BACKUP_ZERO_DOWNTIME=false`.

For each `BACKUP_HOME_TYPE`, `BACKUP_DATABASE_TYPE`, and `BACKUP_ARCHIVE_TYPE` strategy,
additional variables need to be defined in `bitbucket.diy-backup.vars.sh` to configure the
details of your Bitbucket instance's home directory, database, and other options.  Refer
to `bitbucket.diy-backup.vars.sh.example` for a complete description of all the various
variables and their meanings.

### Further reading ###
* [Zero Downtime Backup](https://confluence.atlassian.com/display/BitbucketServer/Using+Bitbucket+Zero+Downtime+Backup)
* [Using Bitbucket Server DIY Backup](https://confluence.atlassian.com/display/BitbucketServer/Using+Bitbucket+Server+DIY+Backup)
* [Using Bitbucket Server DIY Backup in AWS](https://confluence.atlassian.com/display/BitbucketServer/Using+Bitbucket+Server+DIY+Backup+in+AWS)
