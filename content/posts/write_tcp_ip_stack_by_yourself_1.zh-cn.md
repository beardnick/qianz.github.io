---
title: "自己动手编写tcp/ip协议栈1:tcp包解析"
date: 2025-02-17T15:27:18+08:00
tags:
  - tcp/ip
  - network
  - linux
---

# tuntap

由于linux内核控制了网络接口，所以应用层不能直接使用网络接口来处理网络包。linux通过提供tuntap虚拟网络接口的机制，让用户可以在应用层处理原始的网络包。

## tun使用示例

tuntap可以创建两种虚拟网络接口：tun和tap。tap是二层网络接口，提供mac帧。tun是三层网络接口，提供ip包。
我们处理tcp,ip协议，只需要使用tun接口，如果要处理arp，icmp协议则需要使用tap接口。这里只演示tun接口的使用。

[test tun](https://github.com/beardnick/lab/blob/master/scripts/tuntap_test.go#L13-L45)
```go
func Test_tun(t *testing.T) {
    args := struct {
        cidr string
        name string
    }{
        cidr: "11.0.0.1/24",
        name: "testtun1",
    }
    fd, err := CreateTunTap(args.name, syscall.IFF_TUN|syscall.IFF_NO_PI)
    if err != nil {
        log.Fatalln(err)
    }

    out, err := exec.Command("ip", "addr", "add", args.cidr, "dev", args.name).CombinedOutput()
    if err != nil {
        log.Fatalln(err)
    }
    fmt.Println(out)

    out, err = exec.Command("ip", "link", "set", args.name, "up").CombinedOutput()
    if err != nil {
        log.Fatalln(err)
    }
    fmt.Println(out)
    buf := make([]byte, 1024)
    for {
        n, err := syscall.Read(fd, buf)
        if err != nil {
            log.Fatalln(err)
        }
        fmt.Println(hex.Dump(buf[:n]))
    }
}
```

使用curl发送一个简单的请求测试一下

```sh
curl -v  http://11.0.0.2/hello
```

将会得到类似下面的输出，这就是一个原始的ip包了

```
00000000  45 00 00 3c 80 40 40 00  40 06 a4 79 0b 00 00 01  |E..<.@@.@..y....|
00000010  0b 00 00 02 bb f8 00 50  08 a8 4a 04 00 00 00 00  |.......P..J.....|
00000020  a0 02 fa f0 67 67 00 00  02 04 05 b4 04 02 08 0a  |....gg..........|
00000030  bf b6 00 fa 00 00 00 00  01 03 03 07              |............|
```

# 解析ip包

直接看rfc791的对ip包的格式定义

[rfc791#section-3.1](https://datatracker.ietf.org/doc/html/rfc791#section-3.1)
```
0                   1                   2                   3
0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|Version|  IHL  |Type of Service|          Total Length         |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|         Identification        |Flags|      Fragment Offset    |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|  Time to Live |    Protocol   |         Header Checksum       |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                       Source Address                          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                    Destination Address                        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                    Options                    |    Padding    |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

对照着rfc可以来解析如下这个包

```
00000000  45 00 00 3c 80 40 40 00  40 06 a4 79 0b 00 00 01  |E..<.@@.@..y....|
00000010  0b 00 00 02 bb f8 00 50  08 a8 4a 04 00 00 00 00  |.......P..J.....|
00000020  a0 02 fa f0 67 67 00 00  02 04 05 b4 04 02 08 0a  |....gg..........|
00000030  bf b6 00 fa 00 00 00 00  01 03 03 07              |............|
```

结果如下

| IP 偏移量 | TCP 偏移量 | 字节值           | 描述                                                                          |
| ------------ | ------------- | ---------------- | --------------------------------------------------------------------------- |
| 4/8          |               | 0x4              | IP 版本：IPv4                                                               |
| 1            |               | 0x5              | IP 首部长度为 5个32位数字：5 * 4 = 20 字节                                           |
| 2            |               | 0x00             | 服务类型                                                                    |
| 4            |               | 0x003c           | 总长度为 60 字节                                                           |
| 6            |               | 0x8040           | IP 标识                                                                     |
| 6 + 3/8      |               | 010              | 标志位：0: 保留位；必须为 0，1: 禁止分片 (DF) 0: 还有更多分片 (MF)         |
| 8            |               | 0 0000 0000 0000 | 分片偏移量：此处为 0                                                       |
| 9            |               | 0x40             | 生存时间：64 秒                                                            |
| 10           |               | 0x06             | 协议：0x06 表示 TCP                                                        |
| 12           |               | 0xa479           | 首部校验和                                                                  |
| 16           |               | 0x0b 00 00 01    | 源 IP 地址：11.0.0.1                                                       |
| 20           |               | 0x0b 00 00 02    | 目的 IP 地址：11.0.0.2                                                     |


解析的代码如下

[ip.go](https://github.com/beardnick/lab/blob/62e2f4efaff1211860bdb3ea14d0006e7804f56a/network/netstack/tcpip/ip.go#L55-L78)
```go
func (i *IPPack) Decode(data []byte) (*IPPack, error) {
	header := &IPHeader{
		Version:        data[0] >> 4,
		HeaderLength:   (data[0] & 0x0f) * 4,
		TypeOfService:  data[1],
		TotalLength:    binary.BigEndian.Uint16(data[2:4]),
		Identification: binary.BigEndian.Uint16(data[4:6]),
		Flags:          data[6] >> 5,
		FragmentOffset: binary.BigEndian.Uint16(data[6:8]) & 0x1fff,
		TimeToLive:     data[8],
		Protocol:       data[9],
		HeaderChecksum: binary.BigEndian.Uint16(data[10:12]),
		SrcIP:          net.IP(data[12:16]),
		DstIP:          net.IP(data[16:20]),
	}
	header.Options = data[20:header.HeaderLength]
	i.IPHeader = header
	payload, err := i.Payload.Decode(data[header.HeaderLength:])
	if err != nil {
		return nil, err
	}
	i.Payload = payload
	return i, nil
}
```

需要注意的有以下几点

## 网络字节序

网络字节序都是大端的。大端和小端有些时候容易搞混，从网络包解析的场景来说就是解析包时一个数据的高位字节排在前面。
例如`0x1234`，大端表示为`0x1234`，小端表示为`0x3412`。可以发现大端表示法和我们日常书写的顺序一致。
golang中代码实现上也很简单。
```go
func (bigEndian) Uint16(b []byte) uint16 {
	_ = b[1] // bounds check hint to compiler; see golang.org/issue/14808
	return uint16(b[1]) | uint16(b[0])<<8
}

func (littleEndian) Uint16(b []byte) uint16 {
	_ = b[1] // bounds check hint to compiler; see golang.org/issue/14808
	return uint16(b[0]) | uint16(b[1])<<8
}
```

## ip头长度

ip包头的长度单位是32位数字，所以需要乘以4才是字节数。rfc原话是
>   IHL:  4 bits
    Internet Header Length is the length of the internet header in 32
    bit words, and thus points to the beginning of the data.  Note that
    the minimum value for a correct header is 5.

# 解析tcp包

[rfc9293#name-header-format](https://datatracker.ietf.org/doc/html/rfc9293#name-header-format)
```
0                   1                   2                   3
0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|          Source Port          |       Destination Port        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                        Sequence Number                        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                    Acknowledgment Number                      |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|  Data |       |C|E|U|A|P|R|S|F|                               |
| Offset| Rsrvd |W|C|R|C|S|S|Y|I|            Window             |
|       |       |R|E|G|K|H|T|N|N|                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|           Checksum            |         Urgent Pointer        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                           [Options]                           |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                                                               :
:                             Data                              :
:                                                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

对照着rfc可以来解析如下这个包

```
00000000  45 00 00 3c 80 40 40 00  40 06 a4 79 0b 00 00 01  |E..<.@@.@..y....|
00000010  0b 00 00 02 bb f8 00 50  08 a8 4a 04 00 00 00 00  |.......P..J.....|
00000020  a0 02 fa f0 67 67 00 00  02 04 05 b4 04 02 08 0a  |....gg..........|
00000030  bf b6 00 fa 00 00 00 00  01 03 03 07              |............|
```

结果如下

| IP 偏移量 | TCP 偏移量 | 字节值           | 描述                                                                          |
| ------------ | ------------- | ---------------- | --------------------------------------------------------------------------- |
| 22           | 2             | 0xbbf8           | 源端口：48120                                                              |
| 24           | 4             | 0x0050           | 目的端口：80                                                               |
| 28           | 8             | 0x08a84a04       | 序列号：145246724                                                          |
| 32           | 12            | 0x00000000       | 确认号：0                                                                  |
| 33 + 4/8     | 13  + 4/8     | 0xa              | 首部长度为10个32位数字：10 * 4 = 40 字节                                                      |
| 33 + 10/8    | 13  + 10/8    | 0000 00          | 保留位                                                                      |
| 34           | 14            | 00 0010          | 标志位 URG:0 ACK:0 PSH:0 RST:0 SYN:1 FIN:0，所以是syn包                                 |
| 36           | 16            | 0xfaf0           | 窗口大小：64240                                                           |
| 38           | 18            | 0x6767           | 校验和                                                                      |
| 40           | 20            | 0x0000           | 紧急指针                                                                    |
| 60           | 40            |                  | TCP 选项和填充                                                              |

解析的代码如下

[tcp.go](https://github.com/beardnick/lab/blob/1213920ed1e5c48f8a6b028c49cae2490bbecd9e/network/netstack/tcpip/tcp.go#L88-L109)
```go
func (t *TcpPack) Decode(data []byte) (NetworkPacket, error) {
	header := &TcpHeader{
		SrcPort:        binary.BigEndian.Uint16(data[0:2]),
		DstPort:        binary.BigEndian.Uint16(data[2:4]),
		SequenceNumber: binary.BigEndian.Uint32(data[4:8]),
		AckNumber:      binary.BigEndian.Uint32(data[8:12]),
		DataOffset:     (data[12] >> 4) * 4,
		Reserved:       data[12] & 0x0F,
		Flags:          data[13],
		WindowSize:     binary.BigEndian.Uint16(data[14:16]),
		Checksum:       binary.BigEndian.Uint16(data[16:18]),
		UrgentPointer:  binary.BigEndian.Uint16(data[18:20]),
	}
	header.Options = data[20:header.DataOffset]
	t.TcpHeader = header
	payload, err := t.Payload.Decode(data[header.DataOffset:])
	if err != nil {
		return nil, err
	}
	t.Payload = payload
	return t, nil
}
```

有了解析ip包的经验后解析tcp包就简单了，需要注意的点和解析ip包时类似，就不做赘述了。

# 总结

本次我们学习了tuntap中的tun的使用方法，并使用tun接口解析了ip包和tcp包，这是我们自己实现tcp/ip协议栈的第一步。
文章中的代码在[这里](https://github.com/beardnick/lab/tree/master/network/netstack)查看。