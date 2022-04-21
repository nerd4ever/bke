#!/bin/sh
STAGE_DIR=/tmp/bke
BASE_DIR=${STAGE_DIR}/etc/nerd4ever/bke
DIST_DIR=$(pwd)
ARCH="$(/usr/bin/dpkg --print-architecture)"
set -e


if [ ! -d "$1" ]; then
  echo "$1 is not a valid build dir"
  exit 1;
fi
BUILD_DIR="$1"

PATH=/usr/bin:$PATH
export PATH="${PATH}"

echo "Starting..."
echo "Arch: ${ARCH}"
echo "Directory (dist): ${DIST_DIR}"
echo "Directory (build): ${BUILD_DIR}"
echo "Directory (base): ${BASE_DIR}"
echo "Directory (stage): ${STAGE_DIR}"

rm -rf ${STAGE_DIR} | exit 0
mkdir -p ${STAGE_DIR}/DEBIAN
mkdir -p ${BASE_DIR}
echo "Creating package structure..."

cat <<EOF >${STAGE_DIR}/DEBIAN/control
Package: bke
Priority: extra
Section: net
Maintainer: Nerd4ever <support@nerd4ever.com.br>
Version: @VERSION@
Depends: tzdata, ntp, openssh-server, kubelet, kubeadm, kubectl, containerd
Suggests: vim
Pre-Depends: apt-transport-https, ca-certificates, procps, kmod, gnupg , firewalld, curl, lsb-release
Description: Nerd4ever Bare Metal Kubernetes Engine (BKE) is a meta package to provide a complete environment for managing a production kubernetes cluster using OpenSource 
EOF
echo "Architecture: ${ARCH}" >>${STAGE_DIR}/DEBIAN/control

# @see https://kubernetes.io/docs/reference/ports-and-protocols/
cat <<EOF > ${STAGE_DIR}/etc/nerd4ever/bke/iptables.rules
# Nerd4ever Bare Metal Kubernetes Engine (BKE) Firewall Rule Suggested
# @see https://gist.github.com/jirutka/3742890
# @see https://kubernetes.io/docs/reference/ports-and-protocols/
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]

# don't attempt to firewall internal traffic on the loopback device.
-A INPUT -i lo -j ACCEPT

# continue connections that are already established or related to an established 
# connection.
-A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# ---
# synflood deny
# ---
-A FORWARD -p tcp --syn -m limit --limit 1/s -j ACCEPT

# ---
# others (portscanners, ping of death, ataques dos, bad packages e others)
# ---
-A FORWARD -p icmp --icmp-type echo-request -m limit --limit 1/s -j ACCEPT
-A INPUT -p icmp --icmp-type echo-request -m limit --limit 1/s -j ACCEPT
-A FORWARD -p tcp -m limit --limit 1/s -j ACCEPT
-A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
-A FORWARD -p tcp --tcp-flags SYN,ACK,FIN,RST RST -m limit --limit 1/s -j ACCEPT
-A FORWARD --protocol tcp --tcp-flags ALL SYN,ACK -j DROP
-A INPUT -m state --state INVALID -j DROP
-A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
-N VALID_CHECK
-A VALID_CHECK -p tcp --tcp-flags ALL FIN,URG,PSH -j DROP
-A VALID_CHECK -p tcp --tcp-flags ALL SYN,RST,ACK,FIN,URG -j DROP
-A VALID_CHECK -p tcp --tcp-flags ALL ALL -j DROP
-A VALID_CHECK -p tcp --tcp-flags ALL FIN -j DROP
-A VALID_CHECK -p tcp --tcp-flags SYN,RST SYN,RST -j DROP
-A VALID_CHECK -p tcp --tcp-flags SYN,FIN SYN,FIN -j DROP
-A VALID_CHECK -p tcp --tcp-flags ALL NONE -j DROP

# drop non-conforming packets, such as malformed headers, etc.
-A INPUT -m conntrack --ctstate INVALID -j DROP

# block remote packets claiming to be from a loopback address.
-4 -A INPUT -s 127.0.0.0/8 ! -i lo -j DROP
-6 -A INPUT -s ::1/128 ! -i lo -j DROP

# drop all packets that are going to broadcast, multicast or anycast address.
-4 -A INPUT -m addrtype --dst-type BROADCAST -j DROP
-4 -A INPUT -m addrtype --dst-type MULTICAST -j DROP
-4 -A INPUT -m addrtype --dst-type ANYCAST -j DROP
-4 -A INPUT -d 224.0.0.0/4 -j DROP

# chain for preventing SSH brute-force attacks.
# permits 10 new connections within 5 minutes from a single host then drops 
# incomming connections from that host. Beyond a burst of 100 connections we 
# log at up 1 attempt per second to prevent filling of logs.
-N SSHBRUTE
-A SSHBRUTE -m recent --name SSH --set
-A SSHBRUTE -m recent --name SSH --update --seconds 300 --hitcount 10 -m limit --limit 1/second --limit-burst 100 -j LOG --log-prefix "iptables[SSH-brute]: "
-A SSHBRUTE -m recent --name SSH --update --seconds 300 --hitcount 10 -j DROP
-A SSHBRUTE -j ACCEPT

# chain for preventing ping flooding - up to 6 pings per second from a single 
# source, again with log limiting. Also prevents us from ICMP REPLY flooding 
# some victim when replying to ICMP ECHO from a spoofed source.
-N ICMPFLOOD
-A ICMPFLOOD -m recent --set --name ICMP --rsource
-A ICMPFLOOD -m recent --update --seconds 1 --hitcount 6 --name ICMP --rsource --rttl -m limit --limit 1/sec --limit-burst 1 -j LOG --log-prefix "iptables[ICMP-flood]: "
-A ICMPFLOOD -m recent --update --seconds 1 --hitcount 6 --name ICMP --rsource --rttl -j DROP
-A ICMPFLOOD -j ACCEPT

# permit useful icmp packet types for IPv4
# Note: RFC 792 states that all hosts MUST respond to ICMP ECHO requests.
# Blocking these can make diagnosing of even simple faults much more tricky.
# Real security lies in locking down and hardening all services, not by hiding.
-4 -A INPUT -p icmp --icmp-type 0  -m conntrack --ctstate NEW -j ACCEPT
-4 -A INPUT -p icmp --icmp-type 3  -m conntrack --ctstate NEW -j ACCEPT
-4 -A INPUT -p icmp --icmp-type 11 -m conntrack --ctstate NEW -j ACCEPT

# Permit needed ICMP packet types for IPv6 per RFC 4890.
-6 -A INPUT              -p ipv6-icmp --icmpv6-type 1   -j ACCEPT
-6 -A INPUT              -p ipv6-icmp --icmpv6-type 2   -j ACCEPT
-6 -A INPUT              -p ipv6-icmp --icmpv6-type 3   -j ACCEPT
-6 -A INPUT              -p ipv6-icmp --icmpv6-type 4   -j ACCEPT
-6 -A INPUT              -p ipv6-icmp --icmpv6-type 133 -j ACCEPT
-6 -A INPUT              -p ipv6-icmp --icmpv6-type 134 -j ACCEPT
-6 -A INPUT              -p ipv6-icmp --icmpv6-type 135 -j ACCEPT
-6 -A INPUT              -p ipv6-icmp --icmpv6-type 136 -j ACCEPT
-6 -A INPUT              -p ipv6-icmp --icmpv6-type 137 -j ACCEPT
-6 -A INPUT              -p ipv6-icmp --icmpv6-type 141 -j ACCEPT
-6 -A INPUT              -p ipv6-icmp --icmpv6-type 142 -j ACCEPT
-6 -A INPUT -s fe80::/10 -p ipv6-icmp --icmpv6-type 130 -j ACCEPT
-6 -A INPUT -s fe80::/10 -p ipv6-icmp --icmpv6-type 131 -j ACCEPT
-6 -A INPUT -s fe80::/10 -p ipv6-icmp --icmpv6-type 132 -j ACCEPT
-6 -A INPUT -s fe80::/10 -p ipv6-icmp --icmpv6-type 143 -j ACCEPT
-6 -A INPUT              -p ipv6-icmp --icmpv6-type 148 -j ACCEPT
-6 -A INPUT              -p ipv6-icmp --icmpv6-type 149 -j ACCEPT
-6 -A INPUT -s fe80::/10 -p ipv6-icmp --icmpv6-type 151 -j ACCEPT
-6 -A INPUT -s fe80::/10 -p ipv6-icmp --icmpv6-type 152 -j ACCEPT
-6 -A INPUT -s fe80::/10 -p ipv6-icmp --icmpv6-type 153 -j ACCEPT

# Permit IMCP echo requests (ping) and use ICMPFLOOD chain for preventing ping 
# flooding.
-4 -A INPUT -p icmp --icmp-type 8  -m conntrack --ctstate NEW -j ICMPFLOOD
-6 -A INPUT -p ipv6-icmp --icmpv6-type 128 -j ICMPFLOOD

# Accept worldwide access to SSH and use SSHBRUTE chain for preventing 
# brute-force attacks.
-A INPUT -p tcp --dport 22 --syn -m conntrack --ctstate NEW -j SSHBRUTE

# Accept HTTP and HTTPS
-A INPUT -p tcp -m multiport --dports 80,443 --syn -m conntrack --ctstate NEW -j ACCEPT

# Kubelet API (Self, Control plane)
-A INPUT -p tcp --dport 10250 -m conntrack --ctstate NEW -j ACCEPT

# NodePort Services (All)
-A INPUT -p tcp -m multiport --dports 30000:32767 -m conntrack --ctstate NEW -j ACCEPT

# Kubernetes API server (All)
-A INPUT -p tcp --dport 6443 -m conntrack --ctstate NEW -j ACCEPT

# etcd server client API (kube-apiserver, etcd)
-A INPUT -p tcp -m multiport --dports 2379:2380 -m conntrack --ctstate NEW -j ACCEPT

# kube-scheduler (Self)
-A INPUT -p tcp --dport 10259 -m conntrack --ctstate NEW -j ACCEPT

# kube-controller-manager (Self)
-A INPUT -p tcp --dport 10257 -m conntrack --ctstate NEW -j ACCEPT

COMMIT
EOF
cat <<EOF >${STAGE_DIR}/DEBIAN/prerm
#!/bin/bash
# Nerd4ever Bare Metal Kubernetes Engine (BKE)
set -e

# @see https://www.cyberciti.biz/tips/linux-iptables-how-to-flush-all-rules.html
# Accept all traffic first to avoid ssh lockdown  via iptables firewall rules #
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT
 
# Flush All Iptables Chains/Firewall rules #
iptables -F
 
# Delete all Iptables Chains #
iptables -X
 
# Flush all counters too #
iptables -Z 
# Flush and delete all nat and  mangle #
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
iptables -t raw -F
iptables -t raw -X

COMMIT
EOF
cat <<EOF >${STAGE_DIR}/DEBIAN/postinst
#!/bin/bash
# Nerd4ever Bare Metal Kubernetes Engine (BKE)

# synflood deny
echo 1 > /proc/sys/net/ipv4/tcp_syncookies

# icmp broadcasting deny
echo 1 > /proc/sys/net/ipv4/icmp_echo_ignore_broadcasts
echo 1 > /proc/sys/net/ipv4/icmp_echo_ignore_all

# ip spoofing deny
echo 1 > /proc/sys/net/ipv4/conf/all/rp_filter

modprobe overlay
modprobe br_netfilter

sysctl --system
EOF

mkdir -p "${STAGE_DIR}/etc/crio"
cat <<EOF > ${STAGE_DIR}/etc/crio/crio.conf
[crio.runtime]
conmon_cgroup = "pod"
cgroup_manager = "cgroupfs"
EOF

mkdir -p "${STAGE_DIR}/etc/modules-load.d"
# @see https://kubernetes.io/pt-br/docs/setup/production-environment/tools/kubeadm/install-kubeadm/
cat <<EOF >${STAGE_DIR}/etc/modules-load.d/bke.conf
overlay
br_netfilter
EOF

mkdir -p "${STAGE_DIR}/etc/sysctl.d"
cat <<EOF > ${STAGE_DIR}/etc/sysctl.d/99-bke.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

chmod 755 ${STAGE_DIR}/DEBIAN/control
chmod 755 ${STAGE_DIR}/DEBIAN/postinst
chmod 755 ${STAGE_DIR}/DEBIAN/prerm

echo "Creating package..."
dpkg -b "${STAGE_DIR}" "${DIST_DIR}/kbe_@VERSION@_${ARCH}.deb"
echo "Done!"