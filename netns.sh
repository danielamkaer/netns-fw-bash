#!/bin/bash

set -eo pipefail


create_namespace() {
    declare name="$1"
    ip netns add ${name}
    ip netns exec ${name} ip link set lo up
}

add_interface_between_ns() {
    declare name="$1" left="$2" right="$3"

    ip link add ${name}a type veth peer name ${name}b
    ip link set ${name}a netns ${left} up
    ip link set ${name}b netns ${right} up
}

create_bridge() {
    declare name="$1"
    ip link add name ${name} type bridge
    ip link set ${name} up
}

add_ns_interface_to_bridge() {
    declare ns="$1" name="$2" bridge="$3"
    ip link add ${name}a type veth peer name ${name}b
    ip link set ${name}a master ${bridge} up
    ip link set ${name}b netns ${ns} up
}

add_ip6_address() {
    declare ns="$1" if="$2" addr="$3"
    ip netns exec ${ns} ip -6 addr add dev ${if} ${addr}
}

delete_bridge() {
    declare bridge="$1"
    ip link del ${bridge}
}

clean() {
    ip -all netns delete
    delete_bridge iotbr0
}

cmd() {
    local ns="$1"; shift
    local rest="$@"

    ip netns exec ${ns} ${rest}
}

print_header() {
    printf "*%.0s" {1..120}
    echo
    printf "* %-116.116s *\n" "$@"
    printf "*%.0s" {1..120}
    echo
}

routes6() {
    declare ns="$1"
    print_header "Routes for ${ns}"
    cmd ${ns} ip -6 route
}

enable_forwarding6() {
    declare ns="$1"
    cmd ${ns} sysctl -w net.ipv6.conf.default.forwarding=1 > /dev/null
    cmd ${ns} sysctl -w net.ipv6.conf.all.forwarding=1 > /dev/null
}

run_test() {
    local desc="$1"; shift
    local test="$@"
    print_header "Testing: ${desc}"
    ${test}
}


main() {
    clean

    create_bridge iotbr0

    create_namespace iot1
    create_namespace iot2
    create_namespace iot3
    create_namespace gw
    create_namespace cloud1
    create_namespace cloud2
    create_namespace cloud3
    create_namespace pc

    add_interface_between_ns gw_cloud1 gw cloud1
    add_interface_between_ns gw_cloud2 gw cloud2
    add_interface_between_ns gw_cloud3 gw cloud3
    add_interface_between_ns gw_pc0 gw pc

    add_ns_interface_to_bridge gw veth0 iotbr0
    add_ns_interface_to_bridge iot1 veth1 iotbr0
    add_ns_interface_to_bridge iot2 veth2 iotbr0
    add_ns_interface_to_bridge iot3 veth3 iotbr0

    add_ip6_address gw gw_cloud1a 2001:db8:abcd:1::1/64
    add_ip6_address cloud1 gw_cloud1b 2001:db8:abcd:1::2/64
    add_ip6_address gw gw_cloud2a 2001:db8:abcd:2::1/64
    add_ip6_address cloud2 gw_cloud2b 2001:db8:abcd:2::2/64
    add_ip6_address gw gw_cloud3a 2001:db8:abcd:3::1/64
    add_ip6_address cloud3 gw_cloud3b 2001:db8:abcd:3::2/64

    cmd cloud1 ip -6 route add default via 2001:db8:abcd:1::1
    cmd cloud2 ip -6 route add default via 2001:db8:abcd:2::1
    cmd cloud3 ip -6 route add default via 2001:db8:abcd:3::1

    add_ip6_address gw gw_pc0a 2001:db8:1234:2::1/64
    add_ip6_address pc gw_pc0b 2001:db8:1234:2::2/64

    cmd pc ip -6 route add default via 2001:db8:1234:2::1

    add_ip6_address gw veth0b 2001:db8:1234:1::1/64
    add_ip6_address iot1 veth1b 2001:db8:1234:1::3/64
    add_ip6_address iot2 veth2b 2001:db8:1234:1::4/64
    add_ip6_address iot3 veth3b 2001:db8:1234:1::5/64

    cmd iot1 ip -6 route add default via 2001:db8:1234:1::1
    cmd iot2 ip -6 route add default via 2001:db8:1234:1::1
    cmd iot3 ip -6 route add default via 2001:db8:1234:1::1

    enable_forwarding6 gw

    cmd gw ipset create profile1_ip6 hash:ip family inet6
    cmd gw ipset create profile2_ip6 hash:ip family inet6
    cmd gw ipset create profile3_ip6 hash:ip family inet6

    cmd gw ipset add profile1_ip6 2001:db8:1234:1::3
    cmd gw ipset add profile2_ip6 2001:db8:1234:1::4
    cmd gw ipset add profile3_ip6 2001:db8:1234:1::5

    cmd gw ip6tables -P FORWARD DROP
    cmd gw ip6tables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

    cmd gw ip6tables -N forward_iot_in
    cmd gw ip6tables -N forward_iot_in_profile1
    cmd gw ip6tables -N forward_iot_in_profile2
    cmd gw ip6tables -N forward_iot_in_profile3
    cmd gw ip6tables -A FORWARD -s 2001:db8:1234:1::/64 -j forward_iot_in
    cmd gw ip6tables -A forward_iot_in -m set --match-set profile1_ip6 src -j forward_iot_in_profile1
    cmd gw ip6tables -A forward_iot_in -m set --match-set profile2_ip6 src -j forward_iot_in_profile2
    cmd gw ip6tables -A forward_iot_in -m set --match-set profile3_ip6 src -j forward_iot_in_profile3
    cmd gw ip6tables -A forward_iot_in_profile1 -p tcp --dport 1234 -d 2001:db8:abcd:1::/64 -j ACCEPT
    cmd gw ip6tables -A forward_iot_in_profile2 -p tcp --dport 443 -d 2001:db8:abcd:2::/64 -j ACCEPT

    cmd gw ip6tables -N forward_pc_in
    cmd gw ip6tables -A FORWARD -s 2001:db8:1234:2::/64 -j forward_pc_in
    cmd gw ip6tables -A forward_pc_in -j ACCEPT
    cmd gw ip6tables -A forward_pc_in -m set --match-set profile1_ip6 dst -p icmpv6 -j ACCEPT
    cmd gw ip6tables -A forward_pc_in -m set --match-set profile1_ip6 dst -p tcp --dport 80 -j ACCEPT
    cmd gw ip6tables -A forward_pc_in -m set --match-set profile1_ip6 dst -p tcp --dport 443 -j ACCEPT
    cmd gw ip6tables -A forward_pc_in -m set --match-set profile3_ip6 dst -p icmpv6 -j ACCEPT
    cmd gw ip6tables -A forward_pc_in -m set --match-set profile3_ip6 dst -p tcp --dport 443 -j ACCEPT

    cmd gw ip6tables -N forward_inet_in
    cmd gw ip6tables -N forward_inet_in_profile3
    cmd gw ip6tables -A FORWARD ! -s 2001:db8:1234::/48 -j forward_inet_in
    cmd gw ip6tables -A forward_inet_in -s 2001:db8:abcd:3::/64 -j forward_inet_in_profile3
    cmd gw ip6tables -A forward_inet_in_profile3 -m set --match-set profile3_ip6 dst -p icmpv6 -j ACCEPT
    cmd gw ip6tables -A forward_inet_in_profile3 -m set --match-set profile3_ip6 dst -p tcp --dport 443 -j ACCEPT

    cmd gw ip6tables -A FORWARD -j REJECT --reject-with icmp6-adm-prohibited

}

# Profiles:
## Device 1 (Camera)
### Accessible from home network on icmp, tcp/80,443
### Poll for firmware upgrade to cloud service on ip 2001:db8:abcd:1::/64, tcp port 1234
#
## Device 2 (Sensor)
### Pushes updates to cloud service on ip 2001:db8:abcd:2::/64, tcp port 443
#
## Device 3 (Light bulb)
### Accessible from home network on icmp, tcp/443
### Accessible from cloud service on icmp, tcp/443 from ip 2001:db8:abcd:3::/64

main "$@"
