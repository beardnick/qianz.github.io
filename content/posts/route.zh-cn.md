---
title: "linux route"
date: 2024-07-07T06:06:52+08:00
tags:
  - route
  - linux
---

# ip rule 和 ip route

网络包优先匹配 ip rule 中的规则，然后再被转到相应的 ip table 路由规则处理

```sh
ip rule
# output
# 0:      from all lookup local
# 32766:  from all lookup main
# 32767:  from all lookup default
```

这三条规则是内核创建的 \
**前面的数字代表优先级** \
**`from all`代表所有包**

```sh
ip route show table local
# output
# local 127.0.0.0/8 dev lo proto kernel scope host src 127.0.0.1
# local 127.0.0.1 dev lo proto kernel scope host src 127.0.0.1
# broadcast 127.255.255.255 dev lo proto kernel scope link src 127.0.0.1
# local 172.17.0.1 dev docker0 proto kernel scope host src 172.17.0.1
```

所以所有的网络包都会先在本地路由表(local table)中尝试匹配路由规则，如果没有匹配到，就到主路由表(main table)，最后是默认路由表(default table)匹配

**这就是所谓的策略路由,用户也可以创建自己的路由策略(ip rule)以及路由表(ip tables)**

# 调试路由匹配

获取 ip 匹配到的路由规则

```bash
ip route get ip_address
# ip route get 127.0.0.1
```

# 添加路由规则

```bash
# ip in 192.168.3.0/24 should be routed through mytun network interface
ip route add 192.168.3.0/24 dev mytun
```