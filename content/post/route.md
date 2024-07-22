---
title: "linux route basic tutorial"
date: 2024-07-07T06:06:52+08:00
---

# ip rule and ip route

the packet is first matched against ip rules and then directed to specific ip table to match ip route rules

```sh
ip rule
# output
# 0:      from all lookup local
# 32766:  from all lookup main
# 32767:  from all lookup default
```

these three rules are created by the kernel \
**the number is the matching priority** \
**`from all` means all packets**

```sh
ip route show table local
# output
# local 127.0.0.0/8 dev lo proto kernel scope host src 127.0.0.1
# local 127.0.0.1 dev lo proto kernel scope host src 127.0.0.1
# broadcast 127.255.255.255 dev lo proto kernel scope link src 127.0.0.1
# local 172.17.0.1 dev docker0 proto kernel scope host src 172.17.0.1
```

so all the packets will first try to match route rules in the local route table. if no match is found, it will try the main table and then the default table

**this is called policy based routing. you can add your own policies and route tables**

# debug route rules

to determine which route rule has been matched

```bash
ip route get ip_address
# ip route get 127.0.0.1
```

# add route rules

```bash
# ip in 192.168.3.0/24 should be routed through mytun network interface
ip route add 192.168.3.0/24 dev mytun
```
