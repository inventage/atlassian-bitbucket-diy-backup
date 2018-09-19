# Bitbucket Server DIY Backup #

This repository contains a set of example scripts that demonstrate best practices for backing up a Bitbucket Server/Data Center instance using a curated set of vendor technologies.

The scripts contained within this repository enable two categories of backup:

* Backups with downtime. This is the only type of backup available if your Bitbucket instance is older than 4.8 or if you are using the ``rsync`` strategy (described below)
* Zero downtime backups. To enable Zero Downtime Backup, you will need to set the variable `BACKUP_ZERO_DOWNTIME` to `true`.
If true, this variable will backup the filesystem and database **without** locking the application.
 **NOTE:** This is only available from version 4.8 of Bitbucket Server/Data Center, and requires a compatible strategy for taking atomic
block level snapshots of the home directory.

### Strategies ###

In order to use these example scripts you must specify a `BACKUP_DISK_TYPE` and `BACKUP_DATABASE_TYPE` strategy, and optionally a `BACKUP_ARCHIVE_TYPE` and/or `BACKUP_ELASTICSEARCH_TYPE` strategy.
These strategies can be set within the `bitbucket.diy-backup.vars.sh`.

For each `BACKUP_DISK_TYPE`, `BACKUP_DATABASE_TYPE`, `BACKUP_ARCHIVE_TYPE` and `BACKUP_ELASTICSEARCH_TYPE` strategy,
additional variables need to be set in `bitbucket.diy-backup.vars.sh` to configure the details of your Bitbucket instance's home directory, database, and other options.
Refer to `bitbucket.diy-backup.vars.sh.example` for a complete description of all the various variables and their definitions.

`BACKUP_DISK_TYPE` Strategy for backing up the Bitbucket home directory and any configured data stores, valid values are:

* `amazon-ebs`          - Amazon EBS snapshots of the volume(s) containing the home directory and data stores.
* `rsync`               - "rsync" of the home directory and data store contents to a temporary location. **NOTE:** This can NOT be used with `BACKUP_ZERO_DOWNTIME=true`.
* `zfs`                 - ZFS snapshot strategy for home directory and data store backups.

`BACKUP_DATABASE_TYPE` Strategy for backing up the database, valid values are:

* `amazon-rds`           - Amazon RDS snapshots.
* `mysql`                - MySQL using "mysqldump" to backup and "mysql" to restore.
* `postgresql`           - PostgreSQL using "pg_dump" to backup and "pg_restore" to restore.
* `postgresql-fslevel` - PostgreSQL with data directory located in the file system volume as home directory (so that it will be included implicitly in the home volume snapshot).

`BACKUP_ARCHIVE_TYPE`  Strategy for archiving backups and/or copying them to an offsite location, valid values are:

* `<leave-blank>`         - Do not use an archiving strategy.
* `aws-snapshots`        - AWS EBS and/or RDS snapshots, with optional copy to another region.
* `gpg-zip`              - "gpg-zip" archive
* `tar`                  - Unix "tar" archive


`BACKUP_ELASTICSEARCH_TYPE` Strategy for backing up Elasticsearch, valid values are:

* `<leave blank>`        - No separate snapshot and restore of Elasticsearch state (default) 
                         - recommended for Bitbucket Server instances configured to use the (default) bundled Elasticsearch instance. In this case all Elasticsearch state is stored under ${BITBUCKET_HOME}/shared and therefore already included in the home directory snapshot implicitly. NOTE: If Bitbucket is configured to use a remote Elasticsearch instance (which all Bitbucket Data Center instances must be), then its state is NOT included implictly in home directory backups, and may therefore take some to rebuild after a restore UNLESS one of the following strategies is used.
* `amazon-es`           - Amazon Elasticsearch Service - uses an S3 bucket as a snapshot repository. Requires both python and the python package 'boto' to be installed in order to sign the requests to AWS ES. Once python has been installed run 'sudo pip install boto' to install the python boto package.
* `s3`                  - Amazon S3 bucket - requires the Elasticsearch Cloud plugin to be installed. See https://www.elastic.co/guide/en/elasticsearch/plugins/2.3/cloud-aws.html
* `fs`                  - Shared filesystem - requires all data and master nodes to mount a shared file system to the same mount point and that it is configured in the elasticsearch.yml file. See https://www.elastic.co/guide/en/elasticsearch/reference/current/modules-snapshots.html

`STANDBY_DISK_TYPE` Strategy for Bitbucket home directory disaster recovery, valid values are:
*  `zfs`                - ZFS snapshot strategy for disk replication.

`STANDBY_DATABASE_TYPE` Strategy for replicating the database, valid values are:
*  `amazon-rds`         - Amazon RDS Read replica
*  `postgresql`         - PostgreSQL replication

### Configuration ####

You will need to configure the script variables found in `bitbucket.diy-backup.vars.sh` based on your chosen strategies. **Note** that not all options need to be configured. The backup strategy you choose together with your vendor tools will determine which options should be set. See `bitbucket.diy-backup.vars.sh.example` for a complete set of all configuration options.

`BACKUP_ZERO_DOWNTIME` If set to true, the home directory and database will be backed up **without** locking Bitbucket
by placing it in maintenance mode. **NOTE:** This can NOT be used with Bitbucket Server versions older than 4.8. For more information, see [Zero downtime backup](https://confluence.atlassian.com/display/BitbucketServer/Using+Bitbucket+Zero+Downtime+Backup).
Make sure you read and understand this document before uncommenting this variable.

### Bugs and Suggestions ###

Please report any bugs through [normal support channels](https://support.atlassian.com/servicedesk/customer/portal/24).

Report suggestions in the [Bitbucket Server issue tracker](https://jira.atlassian.com/browse/BSERV).

Please note that DIY Backup is intended as a jumping off point for your to create your _own_ back up strategy, and we don't intend to create a solution for all potential configurations of Bitbucket Server.

### Further reading ###
* [Zero Downtime Backup](https://confluence.atlassian.com/display/BitbucketServer/Using+Bitbucket+Zero+Downtime+Backup)
* [Using Bitbucket Server DIY Backup](https://confluence.atlassian.com/display/BitbucketServer/Using+Bitbucket+Server+DIY+Backup)
* [Using Bitbucket Server DIY Backup in AWS](https://confluence.atlassian.com/display/BitbucketServer/Using+Bitbucket+Server+DIY+Backup+in+AWS)