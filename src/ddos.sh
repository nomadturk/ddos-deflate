#!/bin/bash
##############################################################################
# DDoS-Deflate version 0.7 Author: Zaf <zaf@vsnl.com>                        #
##############################################################################
# Contributors:                                                              #
# Jefferson González <jgmdev@gmail.com>                                      #
##############################################################################
# This program is distributed under the "Artistic License" Agreement         #
#                                                                            #
# The LICENSE file is located in the same directory as this program. Please  #
#  read the LICENSE file before you make copies or distribute this program   #
##############################################################################

CONF_PATH="/etc/ddos"
CONF_PATH="${CONF_PATH}/"

load_conf()
{
	CONF="${CONF_PATH}ddos.conf"
	if [ -f "$CONF" ] && [ ! "$CONF" ==	"" ]; then
		source $CONF
	else
		head
		echo "\$CONF not found."
		exit 1
	fi
}

head()
{
	echo "DDoS-Deflate version 0.7"
	echo "Copyright (C) 2005, Zaf <zaf@vsnl.com>"
	echo
}

showhelp()
{
	head
	echo 'Usage: ddos [OPTIONS] [N]'
	echo 'N : number of tcp/udp	connections (default 150)'
	echo
	echo 'OPTIONS:'
	echo '-h | --help: Show this help screen'
	echo '-c | --cron: Create cron job to run this script regularly (default 1 mins)'
	echo '-i | --ignore-list: List whitelisted ip addresses'
	echo '-d | --start: Initialize a daemon to monitor connections'
	echo '-s | --stop: Stop the daemon'
	echo '-t | --status: Show status of daemon and pid if currently running'
	echo '-v | --view: Display active connections to the server'
	echo '-k | --kill: Block all ip addresses making more than N connections'
}

# Check if super user is executing the 
# script and exit with message if not.
su_required()
{
	user_id=`id -u`
	
	if [ "$user_id" != "0" ]; then
		echo "You need super user priviliges for this."
		exit
	fi
}

log_msg()
{
	if [ ! -e /var/log/ddos.log ]; then
		touch /var/log/ddos.log
		chmod 0640 /var/log/ddos.log
	fi
	
	echo "$(date +'[%Y-%m-%d %T]') $1" >> /var/log/ddos.log
}

# Gets a list of ip address to ignore with hostnames on the
# ignore.host.list resolved to ip numbers
ignore_list()
{
	for the_host in $(cat "${CONF_PATH}${IGNORE_HOST_LIST}" | grep -v "#"); do
		host_ip=`nslookup $the_host | tail -n +3 | grep "Address" | awk '{print $2}'`

		# In case an ip is given instead of hostname
		# in the ignore.hosts.list file
		if [ "$host_ip" = "" ]; then
			echo $the_host
		else
            for ips in $host_ip; do
                echo $ips
            done
		fi
	done
	
	# Get ip's of ethernet interfaces to prevent blocking it self.
	for iface_ip in $(ifconfig | grep "inet " | awk '{print $2}' | sed "s/addr://g"); do
		echo $iface_ip
	done
    
    cat "${CONF_PATH}${IGNORE_IP_LIST}"
}

# Generates a shell script that unbans a list of ip's after the
# amount of time given on BAN_PERIOD
unban_ip_list()
{
	UNBAN_SCRIPT=`mktemp /tmp/unban.sh.XXXXXXXX`
	TMP_FILE=`mktemp /tmp/unban.tmp.XXXXXXXX`
	UNBAN_IP_LIST=`mktemp /tmp/unban.ip.XXXXXXXX`
	
	echo '#!/bin/sh' > $UNBAN_SCRIPT
	echo "sleep $BAN_PERIOD" >> $UNBAN_SCRIPT
	
	while read line; do
		if [ "$FIREWALL" = "apf" ]; then
			echo "$APF -u $line" >> $UNBAN_SCRIPT
		elif [ "$FIREWALL" = "csf" ]; then
			echo "$CSF -dr $line" >> $UNBAN_SCRIPT
		elif [ "$FIREWALL" = "iptables" ]; then
			echo "$IPT -D INPUT -s $line -j DROP" >> $UNBAN_SCRIPT
		fi
		
		echo "echo \"\$(date +'[%Y-%m-%d %T]') unbanned $line\" >> /var/log/ddos.log" >> $UNBAN_SCRIPT
		echo $line >> $UNBAN_IP_LIST
	done < $BANNED_IP_LIST
	
	echo "grep -v --file=$UNBAN_IP_LIST ${CONF_PATH}${IGNORE_IP_LIST} > $TMP_FILE" >> $UNBAN_SCRIPT
	echo "mv $TMP_FILE ${CONF_PATH}${IGNORE_IP_LIST}" >> $UNBAN_SCRIPT
	echo "rm -f $UNBAN_SCRIPT" >> $UNBAN_SCRIPT
	echo "rm -f $UNBAN_IP_LIST" >> $UNBAN_SCRIPT
	echo "rm -f $TMP_FILE" >> $UNBAN_SCRIPT
	
	# Launch script in charge of unbanning after the given period of time
	. $UNBAN_SCRIPT &
}

add_to_cron()
{
	su_required
	
	rm -f $CRON
	if [ $FREQ -le 2 ]; then
		echo "0-59/$FREQ * * * * root $SBINDIR/ddos >/dev/null 2>&1" > $CRON
	else
		let "START_MINUTE = $RANDOM % ($FREQ - 1)"
		let "START_MINUTE = $START_MINUTE + 1"
		let "END_MINUTE = 60 - $FREQ + $START_MINUTE"
		echo "$START_MINUTE-$END_MINUTE/$FREQ * * * * root $SBINDIR/ddos >/dev/null 2>&1" > $CRON
	fi
	
	chmod 644 $CRON
	
	log_msg "added cron job"
}

# Check active connections and ban if neccessary.
check_connections()
{
	su_required

	TMP_PREFIX='/tmp/ddos'
	TMP_FILE="mktemp $TMP_PREFIX.XXXXXXXX"
	BAD_IP_LIST=`$TMP_FILE`

	# Original command to get ip's
	#netstat -ntu | awk '{print $5}' | cut -d: -f1 | sort | uniq -c | sort -nr > $BAD_IP_LIST

	# Improved command
	netstat -ntu | \
		# Strip netstat heading
		tail -n +3 | \
		# Match only the given connection states
		grep -E "$CONN_STATES" | \
		# Extract only the fifth column
		awk '{print $5}' | \
		# Strip port without affecting ipv6 addresses (experimental)
		sed "s/:[0-9+]*$//g" | \
		# Sort addresses for uniq to work correctly
		sort | \
		# Group same occurrences of ip and prepend amount of occurences found
		uniq -c | \
		# Numerical sort in reverse order
		sort -nr | \
		# Only store connections that exceed max allowed
		awk "{ if (\$1 >= $NO_OF_CONNECTIONS) print; }" > \
		$BAD_IP_LIST
		
	FOUND=$(cat $BAD_IP_LIST)
	
	if [ "$FOUND" = "" ]; then
		rm -f $BAD_IP_LIST
		
		if [ $KILL -eq 1 ]; then
			echo "No connections exceeding max allowed."
		fi
		
		return 0
	fi
	
	if [ $KILL -eq 1 ]; then
		echo "List of connections that exceed max allowed"
		echo "==========================================="
		cat $BAD_IP_LIST
	fi
	
	BANNED_IP_MAIL=`$TMP_FILE`
	BANNED_IP_LIST=`$TMP_FILE`
	
	echo "Banned the following ip addresses on `date`" > $BANNED_IP_MAIL
	echo >>	$BANNED_IP_MAIL
	
	IP_BAN_NOW=0
	
	while read line; do
		CURR_LINE_CONN=$(echo $line | cut -d" " -f1)
		CURR_LINE_IP=$(echo $line | cut -d" " -f2)
		
		IGNORE_BAN=`ignore_list | grep -c $CURR_LINE_IP`
		
		if [ $IGNORE_BAN -ge 1 ]; then
			continue
		fi
		
		IP_BAN_NOW=1
		
		echo "$CURR_LINE_IP with $CURR_LINE_CONN connections" >> $BANNED_IP_MAIL
		echo $CURR_LINE_IP >> $BANNED_IP_LIST
		echo $CURR_LINE_IP >> "${CONF_PATH}${IGNORE_IP_LIST}"
		
		if [ "$FIREWALL" = "apf" ]; then
			$APF -d $CURR_LINE_IP
		elif [ "$FIREWALL" = "csf" ]; then
			$CSF -d $CURR_LINE_IP
		elif [ "$FIREWALL" = "iptables" ]; then
			$IPT -I INPUT -s $CURR_LINE_IP -j DROP
		fi
		
		log_msg "banned $CURR_LINE_IP with $CURR_LINE_CONN connections for ban period $BAN_PERIOD"
	done < $BAD_IP_LIST
	
	if [ $IP_BAN_NOW -eq 1 ]; then
		if [ $EMAIL_TO != "" ]; then
			dt=`date`
			cat $BANNED_IP_MAIL | mail -s "IP addresses banned on $dt" $EMAIL_TO
		fi
		
		unban_ip_list
		
		if [ $KILL -eq 1 ]; then
			echo "==========================================="
			echo "Banned IP addresses:"
			echo "==========================================="
			cat $BANNED_IP_LIST
		fi
	fi
	
	rm -f $TMP_PREFIX.*
}

# Active connections to server.
view_connections()
{	
	netstat -ntu | \
		# Strip netstat heading
		tail -n +3 | \
		# Match only the given connection states
		grep -E "$CONN_STATES" | \
		# Extract only the fifth column
		awk '{print $5}' | \
		# Strip port without affecting ipv6 addresses (experimental)
		sed "s/:[0-9+]*$//g" | \
		# Sort addresses for uniq to work correctly
		sort | \
		# Group same occurrences of ip and prepend amount of occurences found
		uniq -c | \
		# Numerical sort in reverse order
		sort -nr
}

# Executed as a cleanup function when the daemon is stopped
on_daemon_exit()
{
	if [ -e /var/run/ddos.pid ]; then
		rm -f /var/run/ddos.pid
	fi
	
	exit 0
}

# Return the current process id of the daemon or 0 if not running
daemon_pid()
{
	if [ -e /var/run/ddos.pid ]; then
		echo $(cat /var/run/ddos.pid)
		
		return
	fi
	
	echo "0"
}

# Check if daemon us running.
# Outputs 1 if running 0 if not.
daemon_running()
{
	if [ -e /var/run/ddos.pid ]; then
		running_pid=$(ps -A | grep ddos | awk '{print $1}')
		
		if [ "$running_pid" != "" ]; then
			current_pid=$(daemon_pid)
			
			for pid_num in $running_pid; do
				if [ "$current_pid" = "$pid_num" ]; then
					echo "1"
					return
				fi
			done
		fi
	fi

	echo "0"
}

start_daemon()
{
	su_required
	
	if [ $(daemon_running) = "1" ]; then
		echo "ddos daemon is already running..."
		exit 0
	fi
	
	echo "starting ddos daemon..."
	
	nohup $0 -l > /dev/null 2>&1 &
	
	log_msg "daemon started"
}

stop_daemon()
{
	su_required
	
	if [ $(daemon_running) = "0" ]; then
		echo "ddos daemon is not running..."
		exit 0
	fi
	
	echo "stopping ddos daemon..."
	
	kill $(daemon_pid)
	
	while [ -e /var/run/ddos.pid ]; do
		continue
	done
	
	log_msg "daemon stopped"
}

daemon_loop()
{
	su_required
	
	if [ $(daemon_running) = "1" ]; then
		exit 0
	fi
	
	echo "$$" > /var/run/ddos.pid
	
	trap 'on_daemon_exit' INT
	trap 'on_daemon_exit' QUIT
	trap 'on_daemon_exit' TERM
	trap 'on_daemon_exit' EXIT
	
	detect_firewall
	
	while true; do
		check_connections
		sleep $DAEMON_FREQ
	done
}

daemon_status()
{
	current_pid=$(daemon_pid)
	
	if [ $(daemon_running) = "1" ]; then
		echo "ddos status: running with pid $current_pid"
	else
		echo "ddos status: not running"
	fi
}

detect_firewall()
{
	if [ "$FIREWALL" = "auto" ] || [ "$FIREWALL" = "" ]; then
		apf_where=`whereis apf`;
		csf_where=`whereis csf`;
		ipt_where=`whereis iptables`;
		
		if [ -e "$APF" ]; then
			FIREWALL="apf"
		elif [ -e "$CSF" ]; then
			FIREWALL="csf"
		elif [ -e "$IPT" ]; then
			FIREWALL="iptables"
		elif [ "$apf_where" != "apf:" ]; then
			FIREWALL="apf"
			APF="apf"
		elif [ "$csf_where" != "csf:" ]; then
			FIREWALL="csf"
			CSF="csf"
		elif [ "$ipt_where" != "iptables:" ]; then
			FIREWALL="iptables"
			IPT="iptables"
		else
			echo "error: No valid firewall found."
			log_msg "error: no valid firewall found"
			exit 1
		fi
	fi
}

load_conf

KILL=0

while [ $1 ]; do
	case $1 in
		'-h' | '--help' | '?' )
			showhelp
			exit
			;;
		'--cron' | '-c' )
			add_to_cron
			exit
			;;
		'--ignore-list' | '-i' )
			echo "List of currently whitelisted ip's."
			echo "==================================="
			ignore_list
			exit
			;;
		'--start' | '-d' )
			start_daemon
			exit
			;;
		'--stop' | '-s' )
			stop_daemon
			exit
			;;
		'--status' | '-t' )
			daemon_status
			exit
			;;
		'--loop' | '-l' )
			# start daemon loop, used internally by --start | -s
			daemon_loop
			exit
			;;
		'--view' | '-v' )
			view_connections
			exit
			;;
		'--kill' | '-k' )
			su_required
			KILL=1
			;;
		 *[0-9]* )
			NO_OF_CONNECTIONS=$1
			;;
		* )
			showhelp
			exit
			;;
	esac
	
	shift
done

if [ $KILL -eq 1 ]; then
	detect_firewall
	check_connections
else
	showhelp
fi

exit 0
