#!/bin/bash

# Function to generate random strings
random() {
    tr </dev/urandom -dc A-Za-z0-9 | head -c5
    echo
}

# Array for IP6
array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen64() {
    ip64() {
        echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
    }
    echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
}

# Install necessary packages (changed to use dnf for CentOS 9)
echo "Installing required packages..."
dnf install -y gcc gcc-c++ net-tools tar zip make wget curl iptables-services >/dev/null

# Create working directory
WORKDIR="/home/proxy-installer"
WORKDATA="${WORKDIR}/data.txt"
mkdir -p $WORKDIR && cd $WORKDIR

# Fetch IP4 and Subnet for IP6
IP4=$(curl -4 -s icanhazip.com)
IP6=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')
echo "IP4: $IP4, IP6 Subnet: $IP6"

# Download and install 3proxy
echo "Downloading and installing 3proxy..."
cd /3proxy || mkdir /3proxy && cd /3proxy
wget -q https://github.com/z3APA3A/3proxy/archive/refs/tags/0.9.4.tar.gz
tar -zxvf 0.9.4.tar.gz
cd 3proxy-0.9.4

# Fix poll issue in common.c
sed -i 's/poll,/((int (*)(struct pollfd *, nfds_t, int))poll),/g' src/common.c

# Compile 3proxy
make -f Makefile.Linux CFLAGS="-Wno-incompatible-pointer-types"

# Move 3proxy binary
mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
mv bin/3proxy /usr/local/etc/3proxy/bin/

# Create 3proxy service
wget -q https://raw.githubusercontent.com/xlandgroup/ipv4-ipv6-proxy/master/scripts/3proxy.service-Centos8 -O /usr/lib/systemd/system/3proxy.service
systemctl daemon-reload

# System configuration
echo "* hard nofile 999999" >> /etc/security/limits.conf
echo "* soft nofile 999999" >> /etc/security/limits.conf
echo "net.ipv6.conf.all.proxy_ndp=1" >> /etc/sysctl.conf
echo "net.ipv6.conf.default.forwarding=1" >> /etc/sysctl.conf
echo "net.ipv6.ip_nonlocal_bind = 1" >> /etc/sysctl.conf
sysctl -p

# Disable firewall
systemctl stop firewalld
systemctl disable firewalld

# Generate 3proxy configuration
gen_3proxy() {
    cat <<EOF >/usr/local/etc/3proxy/3proxy.cfg
daemon
maxconn 3000
nserver 1.1.1.1
nserver 1.0.0.1
nserver 2606:4700:4700::64
nserver 2606:4700:4700::6400
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535
stacksize 6291456 
flush
auth strong
users $(awk -F "/" 'BEGIN{ORS="";} {print $1 ":CL:" $2 " "}' ${WORKDATA})
$(awk -F "/" '{print "auth strong\n" \
"allow " $1 "\n" \
"proxy -6 -n -a -p" $4 " -i" $3 " -e"$5"\n" \
"flush\n"}' ${WORKDATA})
EOF
}

# Generate proxy data
gen_data() {
    seq 10000 11000 | while read port; do
        echo "user/password/$IP4/$port/$(gen64 $IP6)"
    done >$WORKDATA
}

# Generate iptables rules
gen_iptables() {
    awk -F "/" '{print "iptables -I INPUT -p tcp --dport " $4 "  -m state --state NEW -j ACCEPT"}' ${WORKDATA} >$WORKDIR/boot_iptables.sh
    chmod +x $WORKDIR/boot_iptables.sh
}

# Generate IP6 configuration
gen_ifconfig() {
    awk -F "/" '{print "ifconfig enp1s0 inet6 add " $5 "/64"}' ${WORKDATA} >$WORKDIR/boot_ifconfig.sh
    chmod +x $WORKDIR/boot_ifconfig.sh
}

# Initialize data and configuration
echo "Generating data and configuration..."
gen_data
gen_iptables
gen_ifconfig
gen_3proxy

# Configure auto-start on boot
cat <<EOF >>/etc/rc.local
bash ${WORKDIR}/boot_iptables.sh
bash ${WORKDIR}/boot_ifconfig.sh
ulimit -n 65535
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg &
EOF
chmod +x /etc/rc.local

# Enable rc.local on boot (if it's not enabled)
chmod +x /etc/rc.d/rc.local
systemctl enable rc-local
systemctl start rc-local

# Start 3proxy
echo "Starting 3proxy..."
bash /etc/rc.local

echo "Installation complete. Proxy is ready!"
