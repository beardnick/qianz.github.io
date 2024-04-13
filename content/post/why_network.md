---
title: "为什么计算机网络要这么设计"
date: 2024-04-13T11:04:55+08:00
draft: true
---

# 为什么需要有ip地址，可不可以只使用mac地址

大家都请楚ip地址最终需要被转换为mac地址才能最终发给目标机器，那为什么不直接使用mac地址进行通信呢?
更大点说为什么

## 假设直接使用mac地址建立计算机网络

机器与机器之间需要通过交换机中转通信，为了能够让互联网上任意两台机器都能互相访问，交换机需要记录非常多的mac地址。

![mac_network.drawio](https://raw.githubusercontent.com/beardnick/static/master/images/mac_network.drawio.svg)

显然把全球的计算机全部连接在一个大交换机上面并不现实，首先是这样做这个交换机将会特别巨大，再者此交换机会变成一个单点，
如果这个交换机崩溃，全球互联网都会崩溃。那么优化一下结构，把交换机分成多级就可以解决这个问题了。

![multilayer_mac_network.drawio](https://raw.githubusercontent.com/beardnick/static/master/images/multilayer_mac_network.drawio.svg)


此时通信的时候每台交换机都需要记录下所有目标mac地址要走的下一跳的交换机。