# OracleHA

Use this script to switchover\failover Oracle database in DG configuration.
Run only on standby server. Without primary database.

# Prerequisites

The script can be used only in Oracle DataGuard Environment. There must be already configured primary ans standby databases. The script is configured and used in operating system RedHat 6.x. It is compatible with Centos 6.x also.

# How to use

Copy the files to /opt/app_scripts directory.

Edit the configuration file name fail.sh.db_name.sh and change the db_name to your database name.
Edit fail.sh.db_name.conf file and set the appropriate values.

Run only on standby database.

Usage example: /opt/app_scripts/fail.sh db status
