#!/bin/bash

# file    : lxc-ansible-container.sh
# purpose : this script will create a ansible management server in a lxc container
# requires: ssh-config, dynamic-inv.sh
#
# author  : harald van der laan
# version : v1.1.0
# date    : 2016/09/13
#
# changelog:
# - v1.0	initial version						(harald)
# - v1.0.1	lots of small changes / bug fixes			(harald)
# - v1.0.2	changed testing to community in repository		(harald)
# - v1.0.3	fixed create keypair when key is not there		(harald)
# - v1.1.0	added support for alpine linux 3.4 ansible was broken
#		by /dev/shm						(harald)

lxcContainerName=${1}
lxcInstallYes="[yY][eE][sS]"

# check if lxc is installed
if [ -z $(which lxc) ]; then
	read -ep "[-]: lxc is not installed, would you like to install it (yes/no): " -i "yes" lxcInstall
	
	# check if this script needs to install lxc
	if [[ ${lxcInstall} =~ ${lxcInstallYes} ]]; then
		# check if user is root or regular user
		if [ ${UID} -eq 0 ]; then
			apt-add-repository ppa:ubuntu-lxc/lxd-stable
			apt-get update
			apt-get install lxd
		else
			sudo apt-add-repository ppa:ubuntu-lxc/lxd-stable
			sudo apt-get update
			sudo apt-get install lxd
		fi
	else
		exit 1
	fi
fi

# check if lxc container name is provided
if [ -z ${lxcContainerName} ]; then
	read -ep "[-]: please enter the ansible container name: " -i "ansible01" lxcContainerName
fi

lxcAlpineImage=$(lxc image list | egrep "^\|\ alpine\ " &> /dev/null; echo ${?})
lxcContainerExists=$(lxc list | egrep "^\|\ ${lxcContainerName}\ " &> /dev/null; echo ${?})

# the ansible management server will be based on alpine linux  (amd64)
# this check will look for the alpine image local
if [ ${lxcAlpineImage} -ne 0 ]; then
	# alpine linux  image is not local
	echo "[ ]: downloading alpine linux  lxc image"
	lxc image copy images:alpine/3.4 local: --alias=alpine &> /dev/null && \ 
		echo "[+]: alpine linux  lxc image downloaded"
fi

# check if there is no container running with the same name
if [ ${lxcContainerExists} -eq 0 ]; then
	echo "[-]: there is a container running with the name: ${lxcContainerName}"
	exit 1
fi

# main script
echo "[ ]: starting clean alpine linux "
lxc launch alpine ${lxcContainerName} &> /dev/null && \
	echo "[+]: clean alpine linux  started"

echo "[ ]: update alpine linux  to latest patch level"
lxc exec ${lxcContainerName} -- apk --update-cache upgrade &> /dev/null && \
	echo "[+]: alpine linux  up to latest patch level"

echo "[ ]: installing requirements (this could take some time)"
lxc exec ${lxcContainerName} -- apk add bash bash-completion git vim python py-pip openssh nmap &> /dev/null && \
	echo "[+]: requirements are installed"

echo "[ ]: installing python modules via pip (this could take some time)"
lxc exec ${lxcContainerName} -- pip install -U pip &> /dev/null && \
	lxc exec ${lxcContainerName} -- pip install -U pysphere &> /dev/null && \
	lxc exec ${lxcContainerName} -- pip install -U pywinrm &> /dev/null && \
	echo "[+]: python modules are installed"

echo "[ ]: installing ansible"
lxc exec ${lxcContainerName} -- apk --update-cache --repository http://dl-3.alpinelinux.org/alpine/edge/community/ add ansible &> /dev/null && \
	echo "[+]: ansible installed"

echo "[ ]: getting ansible data from bitbucket"
lxc exec ${lxcContainerName} -- mkdir /opt
lxc exec ${lxcContainerName} -- git clone https://hvanderlaan@bitbucket.org/hvanderlaan/ansible /opt/ansible
lxc exec ${lxcContainerName} -- ln -s /opt/ansible
echo "[+]: ansible data downloaded"

echo "[ ]: configurating openssh"
lxc exec ${lxcContainerName} -- rc-update add sshd &> /dev/null
lxc exec ${lxcContainerName} -- /etc/init.d/sshd start &> /dev/null
lxc exec ${lxcContainerName} -- mkdir -p /root/.ssh
lxc exec ${lxcContainerName} -- ssh-keygen -b 2048 -t rsa -f /root/.ssh/id_rsa -q -N ""
lxc file pull ${lxcContainerName}/root/.ssh/id_rsa.pub a

if [ ! -f ~/.ssh/id_rsa.pub ]; then
	echo "[ ]: creating public and private key pair"
	mkdir ~/.ssh
	ssh-keygen -b 2048 -t rsa -f /root/.ssh/id_rsa -q -N ""
fi

cat a > authorized_keys
cat ~/.ssh/id_rsa.pub >> authorized_keys
lxc file push authorized_keys ${lxcContainerName}/root/.ssh/authorized_keys --uid=0 --gid=0 --mode=0644
rm a authorized_keys
echo "[+]: openssh is configured"

echo "[ ]: correcting system configuration"
lxc exec ${lxcContainerName} -- sed -i 's/\/bin\/ash/\/bin\/bash/g' /etc/passwd 
if [ -f src/ssh-config ]; then
	lxc file push src/ssh-config ${lxcContainerName}/root/.ssh/config --uid=0 --gid=0 --mode=0644
fi
if [ -f src/dynamic ]; then
	if [ -f src/crontab ]; then
		lxc file push src/crontab ${lxcContainerName}/etc/crontabs/root --uid=0 --gid=0 --mode=0600
		lxc exec ${lxcContainerName} -- mkdir -p /etc/periodic/5min
		cat src/dynamic | sed -e "s/IP/$(ip addr show lxdbr0 | grep inet\ | awk '{print $2}' |cut -d"." -f1,2,3).0\/24/g" > dynamic-inv.sh
		lxc file push dynamic-inv.sh ${lxcContainerName}/etc/periodic/5min/dynamic-inv --uid=0 --gid=0 --mode=0755
		lxc exec ${lxcContainerName} -- /etc/init.d/cron restart &> /dev/null
	else
		cat src/dynamic | sed -e "s/IP/$(ip addr show lxdbr0 | grep inet\ | awk '{print $2}' |cut -d"." -f1,2,3).0\/24/g" > dynamic-inv.sh
		lxc file push dynamic-inv.sh ${lxcContainerName}/root/dynamic-inv.sh --uid=0 --gid=0 --mode=0700
	fi
	rm dynamic-inv.sh
fi

lxcAnsibleIpaddr=$(lxc list | egrep "^\|\ ${lxcContainerName}\ " | awk '{print $6}')
echo "[ ]: correction of shared memory, this is missing"
lxc exec ${lxcContainerName} -- mkdir -p /dev/shm
lxc exec ${lxcContainerName} -- chmod 0777 /dev/shm
lxc file push src/fstab ${lxcContainerName}/etc/fstab --uid=0 --gid=0 --mode=0644
lxc exec ${lxcContainerName} -- mount /dev/shm
echo "[+]: corrections made to shared memory"

echo "[!]: ansible lxc container is ready"
echo "[!]: login: ssh -l root ${lxcAnsibleIpaddr}"
echo

exit 0
