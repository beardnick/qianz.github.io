---
title: "自己动手编写tcp/ip协议栈2:tcp包生成"
date: 2025-02-18T09:59:00+08:00
draft: true
---
 
# 数据结构

上一篇文章较为简单，所以没有详细讲解数据结构的设计，之后的文章难度会逐渐增加，所以这里先介绍一下数据结构的设计。计算机网络是分层结构，除物理层外每一层都有相应的包结构。从链路层到应用层，每一层都会将下一层的包包裹起来，所以我们设计数据结构的时候也设一层包裹一层的形式。基本的构造方法如下：

[packet_test.go](https://github.com/beardnick/lab/blob/62e2f4efaff1211860bdb3ea14d0006e7804f56a/network/netstack/tcpip/packet_test.go#L85)
```go
pack := NewIPPack(NewTcpPack(&RawPack{}))
```

ip对象包裹tcp对象，tcp对象包裹raw对象，生成的是ip对象。构造函数的入参都是接口，所以如果你愿意，你也可以在tcp中再包裹一层ip对象。

```go
pack := NewIPPack(NewTcpPack(NewIPPack(&RawPack{})))
```

这种写法不仅是理论上可行，实际工程中也有意义。一些特殊的网络工具确实是通过在tcp中包裹原始的一些数据包来实现如网络代理之类的功能的。
网络数据包的接口定义如下:

[packet.go](https://github.com/beardnick/lab/blob/62e2f4efaff1211860bdb3ea14d0006e7804f56a/network/netstack/tcpip/packet.go#L3-L6)
```go
type NetworkPacket interface {
	Decode(data []byte) (NetworkPacket, error)
	Encode() ([]byte, error)
}
```

构造函数定义如下:

[tcp.go](https://github.com/beardnick/lab/blob/1213920ed1e5c48f8a6b028c49cae2490bbecd9e/network/netstack/tcpip/tcp.go#L62-L64)
```go
func NewTcpPack(payload NetworkPacket) *TcpPack {
	return &TcpPack{Payload: payload}
}
```

网络包的接口定义非常简单，`Decode`函数将数据包解码为对象，`Encode`函数将对象编码为数据包。

# ip包生成

完整实现如下:

[ip encode](https://github.com/beardnick/lab/blob/62e2f4efaff1211860bdb3ea14d0006e7804f56a/network/netstack/tcpip/ip.go#L80-L116)
```go
func (i *IPPack) Encode() ([]byte, error) {
	var (
		payload []byte
		err     error
	)
	if i.Payload != nil {
		payload, err = i.Payload.Encode()
		if err != nil {
			return nil, err
		}
	}
	data := make([]byte, 0)
	if i.HeaderLength == 0 {
		i.HeaderLength = uint8(20 + len(i.Options))
	}
	data = append(data, i.Version<<4|i.HeaderLength/4)
	data = append(data, i.TypeOfService)
	if i.TotalLength == 0 {
		i.TotalLength = uint16(i.HeaderLength) + uint16(len(payload))
	}
	data = binary.BigEndian.AppendUint16(data, i.TotalLength)
	data = binary.BigEndian.AppendUint16(data, i.Identification)
	data = binary.BigEndian.AppendUint16(data, uint16(i.Flags)<<13|i.FragmentOffset)
	data = append(data, i.TimeToLive)
	data = append(data, i.Protocol)
	data = binary.BigEndian.AppendUint16(data, i.HeaderChecksum)
	data = append(data, i.SrcIP...)
	data = append(data, i.DstIP...)
	data = append(data, i.Options...)
	if i.HeaderChecksum == 0 {
		i.HeaderChecksum = calculateIPChecksum(data)
	}
	binary.BigEndian.PutUint16(data[10:12], i.HeaderChecksum)
	data = append(data, payload...)

	return data, nil
}
```

大部分字段的转换都是一些基础的位运算，这里就不详细解释了。需要注意的是校验和的生成。
校验和的计算稍微有点繁琐，而且也不是tcp,ip协议的重点，如果想要尽快完成一个可以工作的tcp,ip协议实现，可以暂时跳过，直接拷贝现成的实现代码即可。
不过不能不管校验和，校验不通过的包会直接被丢弃。

## 校验和

计算校验和要先生成ip的头的数据包，生成的包中checksum字段为0，然后对数据包进行校验和计算。
rfc原文如下
[checksum](https://datatracker.ietf.org/doc/html/rfc1071#autoid-1)
```
In outline, the Internet checksum algorithm is very simple:
(1)  Adjacent octets to be checksummed are paired to form 16-bit
    integers, and the 1's complement sum of these 16-bit integers is
    formed.
(2)  To generate a checksum, the checksum field itself is cleared,
    the 16-bit 1's complement sum is computed over the octets
    concerned, and the 1's complement of this sum is placed in the
    checksum field.
```
    
翻译过来就是相邻的8位字节组成16位整数，然后对这些整数求反码(1's complement)和，最后对这个和取反码。
下面还有另外一段原文补充:

```
On a 2's complement machine, the 1's complement sum must be
computed by means of an "end around carry", i.e., any overflows
from the most significant bits are added into the least
significant bits. See the examples below.
```

翻译过来就是在补码(2's complement)表示的机器上对于溢出的处理，将溢出的部分加到最低位。
所以计算反码和的实现如下

[packet.go](https://github.com/beardnick/lab/blob/1d1b52ebe48c46a76104021167157a6bd894c104/network/netstack/tcpip/packet.go#L27-L37)
```go
func OnesComplementSum(data []byte) uint16 {
	var sum uint16
	for i := 0; i < len(data); i += 2 {
		sum += binary.BigEndian.Uint16(data[i : i+2])
		// if sum is less than the current byte, it means there is a carry
		if sum < binary.BigEndian.Uint16(data[i:i+2]) {
			sum++ // handle carry
		}
	}
	return sum
}
```

聪明的读者可能已经发现了，这个函数要求入参是偶数长度的字节数组。rfc中对奇数的情况这样说明

```
A, B, C, D, ... , Y, Z.  Using the notation [a,b] for the 16-bit
integer a*256+b, where a and b are bytes, then the 16-bit 1's
complement sum of these bytes is given by one of the following:

    [A,B] +' [C,D] +' ... +' [Y,Z]              [1]

    [A,B] +' [C,D] +' ... +' [Z,0]              [2]

where +' indicates 1's complement addition. These cases
correspond to an even or odd count of bytes, respectively.
```

也就是如果字节数是奇数，那么在末尾填充一个0字节。
综上，ip包的校验和计算如下:

[ip checksum](https://github.com/beardnick/lab/blob/62e2f4efaff1211860bdb3ea14d0006e7804f56a/network/netstack/tcpip/ip.go#L118-L124)
```go
// https://datatracker.ietf.org/doc/html/rfc1071#autoid-1
func calculateIPChecksum(headerData []byte) uint16 {
	if len(headerData)%2 == 1 {
		headerData = append(headerData, 0)
	}
	return ^OnesComplementSum(headerData)
}
```

# tcp包生成

[tcp encode](https://github.com/beardnick/lab/blob/c030899077b98d44d8f750d8371befa457a87de0/network/netstack/tcpip/tcp.go#L111-L141)
```go
func (t *TcpPack) Encode() ([]byte, error) {
	data := make([]byte, 0)
	data = binary.BigEndian.AppendUint16(data, t.SrcPort)
	data = binary.BigEndian.AppendUint16(data, t.DstPort)
	data = binary.BigEndian.AppendUint32(data, t.SequenceNumber)
	data = binary.BigEndian.AppendUint32(data, t.AckNumber)
	if t.DataOffset == 0 {
		t.DataOffset = uint8(20 + len(t.Options))
	}
	data = append(data, ((t.DataOffset>>2)<<4)|t.Reserved)
	data = append(data, t.Flags)
	data = binary.BigEndian.AppendUint16(data, t.WindowSize)
	data = binary.BigEndian.AppendUint16(data, t.Checksum)
	data = binary.BigEndian.AppendUint16(data, t.UrgentPointer)
	data = append(data, t.Options...)
	if t.Payload != nil {
		payload, err := t.Payload.Encode()
		if err != nil {
			return nil, err
		}
		data = append(data, payload...)
	}
	if t.Checksum == 0 {
		if t.PseudoHeader == nil {
			return nil, errors.New("pseudo header is required to calculate tcp checksum")
		}
		t.Checksum = calculateTcpChecksum(t.PseudoHeader, data)
		binary.BigEndian.PutUint16(data[16:18], t.Checksum)
	}
	return data, nil
}
```

tcp包的生成也只有校验和比较复杂，同样的，如果想要尽快完成一个可以工作的tcp,ip协议实现，可以暂时跳过，直接拷贝现成的实现代码即可。

## 校验和

tcp包的校验和计算在需要对tcp包头加上一些额外数据，然后再使用函数计算这个数据包的校验和。rfc原文如下

[pseudo-header](https://datatracker.ietf.org/doc/html/rfc9293)
```
The checksum also covers a pseudo-header (Figure 2) conceptually prefixed to the TCP header.
+--------+--------+--------+--------+
|           Source Address          |
+--------+--------+--------+--------+
|         Destination Address       |
+--------+--------+--------+--------+
|  zero  |  PTCL  |    TCP Length   |
+--------+--------+--------+--------+
Figure 2: IPv4 Pseudo-header

Pseudo-header components for IPv4:
    Source Address: the IPv4 source address in network byte order
    Destination Address: the IPv4 destination address in network byte order
    zero: bits set to zero
    PTCL: the protocol number from the IP header
    TCP Length: the TCP header length plus the data length in octets (this is not an explicitly transmitted quantity but is computed), and it does not count the 12 octets of the pseudo-header.
```

所以我们先要生成伪头，然后计算校验和，伪头的数据都可以简单地从ip包中获取到。生成新数据包后再使用计算ip校验和相同的函数计算校验和即可，最终实现如下:

[tcp checksum](https://github.com/beardnick/lab/blob/c030899077b98d44d8f750d8371befa457a87de0/network/netstack/tcpip/tcp.go#L143-L165)
```go
func (t *TcpPack) SetPseudoHeader(srcIP, dstIP []byte) {
	t.PseudoHeader = &PseudoHeader{SrcIP: srcIP, DstIP: dstIP}
}

// https://datatracker.ietf.org/doc/html/rfc1071#autoid-1
func calculateTcpChecksum(pseudo *PseudoHeader, headerPayloadData []byte) uint16 {
	length := uint32(len(headerPayloadData))
	pseudoHeader := make([]byte, 0)
	pseudoHeader = append(pseudoHeader, pseudo.SrcIP...)
	pseudoHeader = append(pseudoHeader, pseudo.DstIP...)
	pseudoHeader = binary.BigEndian.AppendUint32(pseudoHeader, uint32(ProtocolTCP))
	pseudoHeader = binary.BigEndian.AppendUint32(pseudoHeader, length)

	sumData := make([]byte, 0)
	sumData = append(sumData, pseudoHeader...)
	sumData = append(sumData, headerPayloadData...)

	if len(sumData)%2 == 1 {
		sumData = append(sumData, 0)
	}

	return ^OnesComplementSum(sumData)
}
```

# 校验和计算性能优化

校验和计算有非常多的优化方法，这里介绍一种使用uint32计算的优化方法。
直接使用uint32计算，所有溢出的部分都加到了高16位，然后我们把高16位加回到低16位即可，如果再次溢出则继续加回到低16位，直到不再溢出为止。

```go
func OnesComplementSum(data []byte) uint16 {
	var sum uint32
	for i := 0; i < len(data); i += 2 {
		sum += uint32(binary.BigEndian.Uint16(data[i : i+2]))
	}
	// Add the carry bits back in
	for sum > 0xffff {
		sum = (sum & 0xffff) + (sum >> 16)
	}
	return uint16(sum)
}
```

# 注意事项

- 我的协议栈项目主要以教学为目的，所以我优先保证代码的可读性，其次是性能，所以很多实现都不是最优的。实际生产级别的代码会做大量的性能优化、错误处理、边界检查，一定程度上牺牲可读性换来更高的性能和安全性。
- 现有的实现中ip id始终为0，这是为了简化实现，ip id主要在ip分片的时候使用，所以这里可以先忽略，现在的实现在小包的情况下可以正常工作。
- ip, tcp都有options字段，涉及到一些扩展的网络功能，也可以先忽略不实现。

# 推荐阅读

- [通用网络包处理库](https://github.com/google/gopacket)
- [生产级别的用户态tcp/ip协议栈实现](https://github.com/google/netstack)

# 总结

至此，我们已经完成了tcp包的生成，下一篇文章我们将开始实现tcp三次握手。