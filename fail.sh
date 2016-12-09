#!/bin/bash 
# fail.sh
# (c) Karapet Kuyumjyan 2015
# -Use this script to switchover\failover Oracle database in DG configuration. 
# -Configuration settings should be placed to current directory into file:
# -Run only on standby server. Without primary database.
# -Please put the script to the same directory on both servers.
#


#DO NOT CHANGE THIS LINE
export tmpf=~oracle/.fail_cmd.sh
export DEBUG=2
#DO NOT CHANGE THIS LINE

#functions

## common

set_config() {
export SCRIPT_DIR=`pwd`;

#read configuration file from current directory or
#ask if there are some config files, but SID variable is not set

if [ -e $0.${SID}.conf ]; then
	. $0.${SID}.conf
	return 0
else
	echo 'Set SID environment variable and rerun the script.'
	echo 'You have configuration files for this services:'
	ls -1 $0.*.conf | sed -e 's/\.conf$//g' -e 's/^.*\.//g'
	echo -ne 'Type service name to use:'
	read
	export SID=$REPLY
	if [ -e $0.${SID}.conf ]; then
		#read config file and exit
		. $0.${SID}.conf
		return 0
	else
		#just exit
		return 1
	fi
fi
}

log_msg() {
	case "$DEBUG" in
		0)
		;;
		1)
			logger "$0 : $1"
		;;
		2)
			echo "$0: $1" >&2
			logger "$0 : $1"
		;;
	esac
	return 0;
}

acquireIP() {
	#move service IP to this host
	#after that all connections will be moved* from other node
	#*moved - all related connections should be reinitiated
	ping -c 2 $service_ip &>/dev/null
	if [ $? -ne 0 ]; then
		ip addr add ${service_ip}/24 dev ${service_eth_int}
	else
		ip addr list ${service_eth_int} | grep ${service_ip} &>/dev/null
		if [ $? -ne 0 ]; then
			ssh ${remote_host_ip} "ip addr del ${service_ip}/24 dev ${service_eth_int}"
			ip addr add ${service_ip}/24 dev ${service_eth_int}
		else
			log_msg "IP acquire[ ${service_ip}/24 ] - OK"
			return 0
		fi
	fi
	ip addr list ${service_eth_int} | grep ${service_ip} &>/dev/null
	if [ $? -ne 0 ]; then
		log_msg "IP acquire[ ${service_ip}/24 ] - FAILED"
		return 1
	else
		log_msg "IP acquire[ ${service_ip}/24 ] - OK"
		return 0
	fi
}

releaseIP() {
	#Release IP to prevent connections when service is down
	# be careful this will close all connections
	ip addr list ${service_eth_int} | grep ${service_ip} &>/dev/null
	if [ $? -eq 0 ]; then
		ip addr del ${service_ip}/24 dev ${service_eth_int}	
	else
		#already released\or was not here
		log_msg "IP release [ ${service_ip}/24 ] - OK"
		return 0
	fi
	
	ip addr list ${service_eth_int} | grep ${service_ip} &>/dev/null
	if [ $? -eq 0 ]; then
		log_msg "IP release [ ${service_ip}/24 ] - FAILED"
		return 1
	else
		log_msg "IP release [ ${service_ip}/24 ] - OK"
		return 0
	fi
}

## database related

db_switchover() {
#run switchover of the oracle database. See oracle documentation.
#Create loooong script and run it as user 'oracle'
#$1 - local(primary) instance tns
#$2 - remote(standby) instance tns
	export STNS=$1
	export PTNS=$2
	
	db_status $local_instance_stb $remote_instance_pr | grep `hostname` | grep 'PHYSICAL STANDBY' &>/dev/null
	if [ $? -ne 0 ]; then
		log_msg "Switchover ${SID}. Could not complete operation. Run the command on standby database."
		return 1
	fi
	
	#disable synchronization from remote host if this is standby db and vice versa
	if [ "x${APP_SYNC_FLAG}" == "x" ]; then
		log_msg "APP_SYNC_FLAG was not set."
		return 1
	fi
	
	if [ ${APP_SYNC_FLAG} -eq 1 ]; then
		str1=`grep APP_SYNC_FLAG $0.${SID}.conf | grep ^export`
		str2=`echo $str1 | sed 's/\=\ *[0-1]/\=0/g'`
		sed -i "s/$str1/$str2/g" $0.${SID}.conf
		log_msg "Sync to local server disabled."
	else
		ssh ${remote_host_ip} "export SID=${SID}; cd ${SCRIPT_DIR}; str1=\`grep APP_SYNC_FLAG $0.\${SID}.conf | grep ^export\` ; str2=\`echo \$str1 | sed 's/\=\ *[0-1]/\=0/g'\` ; sed -i \"s/\$str1/\$str2/g\" $0.\${SID}.conf"
		if [ $? -ne 0 ]; then
			log_msg "CRITITCAL: Sync to remote server could not be enabled. Manual intervention required."
			return 1
		fi
	fi
	
	
	# make script for oracle user
	cat > $tmpf <<EOD
#!/bin/bash 
. ~/.bash_profile
log_msg() {
	case "$DEBUG" in
		0)
		;;
		1)
			logger "$0: \$1"
		;;
		2)
		echo "$0: \$1" >&2
		logger "$0: \$1"
		;;
	esac
	return 0;
}

	
	#Convert Primary DB
	echo 'select open_mode, database_role, switchover_status from v\$database;' | sqlplus ${username}/${password}@${PTNS} as sysdba 2>&1 | grep 'TO STANDBY' &>/dev/null
	if [ \$? -ne 0 ]; then 
		log_msg '(Primary DB)Selected DB could not be switched to standby database. Wrong status'
		exit 1
	fi
	echo 'ALTER DATABASE COMMIT TO SWITCHOVER TO STANDBY;' | sqlplus ${username}/${password}@${PTNS} as sysdba 2>&1 | grep -v 'ORA-32004' |grep 'ORA-' &>/dev/null
	if [ \$? -eq 0 ]; then 
		log_msg '(Primary DB)Selected DB could not be switched to standby database. Check alert log.'
		exit 1
	fi
	echo 'shutdown immediate;' | sqlplus ${username}/${password}@${PTNS} as sysdba 2>&1;
	echo 'select status from v\$instance;' | sqlplus ${username}/${password}@${PTNS} as sysdba 2>&1 | egrep -e '(MOUNT|OPEN|NOMOUNT)' &>/dev/null
	if [ \$? -eq 0 ]; then 
		log_msg 'Primary DB was not shutdown. Check alert log.'
		exit 1
	fi

	echo 'STARTUP NOMOUNT;
		
	ALTER DATABASE MOUNT STANDBY DATABASE;

	ALTER DATABASE RECOVER MANAGED STANDBY DATABASE DISCONNECT FROM SESSION;' | sqlplus ${username}/${password}@${PTNS} as sysdba 2>&1 | grep -v 'ORA-32004' | grep 'ORA-' &>/dev/null
	if [ \$? -eq 0 ]; then 
		log_msg '(old Primary DB)Conversion to standby went wrong. Check alert log.'
		exit 1
	fi
	#we need this stupid sleep fuction to make sure that standby database could be converted to primary
	sleep 10
	#Convert Standby DB
	echo 'select open_mode, database_role, switchover_status from v\$database;' | sqlplus ${username}/${password}@${STNS} as sysdba 2>&1 | grep 'TO PRIMARY' &>/dev/null
	if [ \$? -ne 0 ]; then 
		log_msg '(Standby DB)Selected DB could not be switched to primary database. Wrong status'
		exit 1
	fi
	echo 'ALTER DATABASE COMMIT TO SWITCHOVER TO PRIMARY; 
	
	shutdown immediate;
	' | sqlplus ${username}/${password}@${STNS} as sysdba 2>&1;
	echo 'select status from v\$instance;' | sqlplus ${username}/${password}@${STNS} as sysdba 2>&1 | egrep -e '(MOUNT|OPEN|NOMOUNT)' &>/dev/null
	if [ \$? -eq 0 ]; then 
		log_msg '(old Standby DB) was not shutdown. Check alert log.'
		exit 1
	fi
	echo 'startup mount;
	alter database open;
	alter system switch logfile;' | sqlplus ${username}/${password}@${STNS} as sysdba 2>&1;
	echo 'select status from v\$instance;' | sqlplus ${username}/${password}@${STNS} as sysdba 2>&1 | egrep -e '(OPEN)' &>/dev/null
	if [ \$? -ne 0 ]; then 
		log_msg '(new Primary DB) was not started. Check alert log.'
		exit 1
	fi
	echo 'Done'
	
EOD

	chmod 700 $tmpf
	if [ ! -e "${tmpf}" ]; then
		log_msg "CRITICAL: Could not create ${tmpf} check permissions."
		return 1
	fi
	chown oracle:oinstall $tmpf
	su - oracle -c $tmpf
	if [ $? -ne 0 ]; then
		#disable synchronization from remote host if this is standby db and vice versa
		if [ "x${APP_SYNC_FLAG}" == "x" ]; then
			log_msg "APP_SYNC_FLAG was not set."
			return 1
		fi
		#failback
		if [ ${APP_SYNC_FLAG} -eq 1 ]; then
			str1=`grep APP_SYNC_FLAG $0.${SID}.conf | grep ^export`
			str2=`echo $str1 | sed 's/\=\ *[0-1]/\=1/g'`
			sed -i "s/$str1/$str2/g" $0.${SID}.conf
			log_msg "Sync to local server disabled."
		else
			ssh ${remote_host_ip} "export SID=${SID}; cd ${SCRIPT_DIR}; str1=\`grep APP_SYNC_FLAG $0.\${SID}.conf | grep ^export\` ; str2=\`echo \$str1 | sed 's/\=\ *[0-1]/\=1/g'\` ; sed -i \"s/\$str1/\$str2/g\" $0.\${SID}.conf"
			if [ $? -ne 0 ]; then
				log_msg "CRITITCAL: Sync to remote server could not be enabled. Manual intervention required."
				return 1
			fi
		fi
	fi
	
	
	su - oracle -c "rm -f ${tmpf}"
	
	
	
	
	#Enable synchronization on remote host if needed
	#FIXME: Check this after switchover. APP_SYNC_FLAG could be in wrong status
	if [ ${APP_SYNC_FLAG} -eq 1 ]; then
		ssh ${remote_host_ip} "export SID=${SID}; cd ${SCRIPT_DIR}; str1=\`grep APP_SYNC_FLAG $0.\${SID}.conf | grep ^export\` ; str2=\`echo \$str1 | sed 's/\=\ *[0-1]/\=1/g'\` ; sed -i \"s/\$str1/\$str2/g\" $0.\${SID}.conf"
		if [ $? -ne 0 ]; then
			log_msg "CRITITCAL: Sync to remote server could not be enabled. Manual intervention required."
			return 1
		fi
	else
		str1=`grep APP_SYNC_FLAG $0.${SID}.conf | grep ^export`
		str2=`echo $str1 | sed 's/\=\ *[0-1]/\=1/g'`
		sed -i "s/$str1/$str2/g" $0.${SID}.conf
		log_msg "Sync to local server disabled."
	fi
	log_msg "Sync to remote server enabled."
}

db_failover() {
#Failover - standby database become primary database.
#This could be run ONLY if primary DB completely crashed.

	#disable synchronization from remote host
	if [ "x${APP_SYNC_FLAG}" == "x" ]; then
		log_msg "APP_SYNC_FLAG was not set."
		return 1
	fi
	
	
	
	str1=`grep APP_SYNC_FLAG $0.${SID}.conf | grep ^export`
	str2=`echo $str1 | sed 's/\=\ *[0-1]/\=0/g'`
	sed -i "s/$str1/$str2/g" $0.${SID}.conf
	log_msg "Sync to local server disabled."

# $1 - standby db
export STNS=$1
#create failover script for user 'oracle'
	cat > $tmpf <<EOD
#!/bin/bash 
. ~/.bash_profile
log_msg() {
	case "$DEBUG" in
		0)
		;;
		1)

			logger "$0: \$1"
		;;
		2)
		echo "$0: \$1" >&2
		logger "$0: \$1"
		;;
	esac
	return 0;
}

	#Convert Standby DB
	echo 'ALTER DATABASE RECOVER MANAGED STANDBY DATABASE FINISH;' | sqlplus ${username}/${password}@${STNS} as sysdba 2>&1 | grep -v 'ORA-32004' | grep 'ORA-' &>/dev/null
	if [ \$? -eq 0 ]; then 
		log_msg '(Standby DB)Selected DB could not be switched to primary database. Wrong status'
		exit 1
	fi
	echo 'ALTER DATABASE ACTIVATE STANDBY DATABASE;
	' | sqlplus ${username}/${password}@${STNS} as sysdba 2>&1;
	echo 'select status from v\$instance;' | sqlplus ${username}/${password}@${STNS} as sysdba 2>&1 | egrep -e '(OPEN)' &>/dev/null
	if [ \$? -ne 0 ]; then 
		log_msg '(new Primary DB) Failover error. Check alert log.'
		exit 1
	fi
EOD
	chmod 700 $tmpf
	chown oracle:oinstall $tmpf
	if [ ! -e "${tmpf}" ]; then
		log_msg "CRITICAL: Could not create ${tmpf} check permissions."
		return 1
	fi
	su - oracle -c $tmpf
	su - oracle -c "rm -f ${tmpf}"

}

db_status() {
#Shows status of both databases.
#FIXME: Make output more useful.
	export STNS=$1
	export PTNS=$2
	#echo $STNS
        su - oracle -c "echo 'set linesize 300
col WALLET_STATUS format a14
col HOST format a14
select c.instance_name,c.HOST_NAME as HOST, a.open_mode, a.database_role, a.switchover_status, b.status as WALLET_STATUS,d.status as ARCHLOG_DEST from (select open_mode, database_role, switchover_status from v\$database) a , (select status from v\$encryption_wallet) b, (select instance_name,HOST_NAME from v\$instance) c, (select status from v\$archive_dest where dest_id=2) d;' |
sqlplus ${username}/${password}@${STNS} as sysdba" | grep -B 1 -A 1 "^------------"
	RETVAL=$?

	#echo $PTNS
	#su - oracle -c "echo 'select open_mode, database_role, switchover_status from v\$database;' | sqlplus ${username}/${password}@${PTNS} as sysdba"
	    su - oracle -c "echo 'set linesize 300
col WALLET_STATUS format a14
col HOST format a14
select c.instance_name,c.HOST_NAME as HOST, a.open_mode, a.database_role, a.switchover_status, b.status as WALLET_STATUS,d.status as ARCHLOG_DEST from (select open_mode, database_role, switchover_status from v\$database) a , (select status from v\$encryption_wallet) b, (select instance_name,HOST_NAME from v\$instance) c, (select status from v\$archive_dest where dest_id=2) d;' |
sqlplus ${username}/${password}@${PTNS} as sysdba" | grep -A 1 "^------------"
	RETVAL=$(($RETVAL + $?))
	return $RETVAL
}

db_start() {
	# local instance
	export STNS=$1
	# remote instance
	export PTNS=$2
	
	#disable synchronization from remote host
	#FIXME: stop this copy\paste - create function
	if [ "x${APP_SYNC_FLAG}" == "x" ]; then
		log_msg "CRITICAL: APP_SYNC_FLAG was not set. Set 1 if this server should run standby database and 0 if primary DB"
		return 1
	fi

	
	# start primary db
	if [ ${APP_SYNC_FLAG} -eq 0 ]; then
		#if this is a primary instance - switch TNS to start right DB
		PTNS1=${PTNS}
		export PTNS=${STNS}
		export STNS=${PTNS1}
		unset PTNS1
		su - oracle -c "echo 'startup mount;
		
alter database open;
		
' | sqlplus ${username}/${password}@${PTNS} as sysdba 2>&1" | grep -v 'ORA-32004' | grep 'ORA-' &>/dev/null
		if [ $? -eq 0 ]; then
			log_msg "(Primary DB ${SID})Errors found when starting the database instance. Check alert log."
			return 1
		fi
	else
		# start standby db
		su - oracle -c "echo 'STARTUP NOMOUNT;

ALTER DATABASE MOUNT STANDBY DATABASE;

ALTER DATABASE RECOVER MANAGED STANDBY DATABASE DISCONNECT FROM SESSION;
' | sqlplus ${username}/${password}@${STNS} as sysdba 2>&1 | grep -v 'ORA-32004' | grep 'ORA-' &>/dev/null"
		if [ $? -eq 0 ]; then 
			log_msg "(Standby DB ${SID})Errors found when starting the database instance. Check alert log."
			return 1
		fi
	fi
	return 0
	
}

## common script routing functions

usage() {
cat <<EOD
Please read Oracle 11g documentation chapter about "Data Guard" before use.
Use this script only when you know what you are doing.

Run only on standby database.

usage:
	$0 <context> <command>
	context:
		db - run database related commands
	db commands:
		switchover - (ONLY on the server with standby database). Run if you need to switch active database to another server.  
		failover - run ONLY IF another server was completely annihilated.
		status - show status of the databases: current instance_name,role etc
		getip - move service IP to this host (this will break all existing connections)
EOD

}

db_cmd() {
#database related actions
case "$1" in
	switchover)
		log_msg "WARNING Database switchover initiated.(service ${SID}) "
		echo -ne "Are you sure?"
		echo -ne '[y/N]:'
		read
		if [ "x$REPLY" != "xy" ]; then
			log_msg "Exiting."
			exit 0
		fi
		acquireIP
		if [ $? -ne 0 ];then
			log_msg "Could not acquire service IP address."
			exit 1
		fi
		# run switchover, do not forget to move IP to this host
		db_switchover $local_instance_stb $remote_instance_pr
	;;
	failover)
		log_msg "WARNING Database failover initiated.(service ${SID}) Old primary database must be recreated."
		echo "WARNING You must recreate standby(or old primary) database after this operation. WARNING"
		echo -ne "Are you sure?"
		echo -ne '[y/N]:'
		read
		if [ "x$REPLY" != "xy" ]; then
			log_msg "Exiting."
			exit 0
		fi
		# getting service IP. We need it on this machine to provide access to primary DB.
		acquireIP
		if [ $? -ne 0 ];then
			log_msg "Could not acquire service IP address."
			exit 1
		fi
		# run failover
		db_failover $local_instance_stb
	;;
	status)
		db_status $local_instance_stb $remote_instance_pr
		if [ $? -ne 0 ]; then
			log_msg "CRITICAL: Status of one of the ${SID} databases could not be checked."
			return 1
		fi
		return 0
	;;
	start)
		log_msg "Starting DB for service ${SID}"
		db_start $local_instance_stb $remote_instance_pr
	;;
	getip)
		acquireIP
	;;
	*)
		usage
	;;
esac
}

#Action

set_config
if [ $? -ne 0 ]; then
	log_msg "Unable to read configuration file."
	exit 1
fi

# We need to control db switch and application files sync.
case "$1" in
	db)
		db_cmd $2
	;;
	*)
		usage
	;;
esac