---
title: "Write TCP/IP Stack by Yourself (2): TCP Packet Generation"
date: 2025-02-18T09:59:00+08:00
---

# Data Structures

The previous article was relatively simple, so we didn't discuss the data structure design in detail. As the following articles will gradually increase in complexity, let's first introduce the data structure design. Computer networks have a layered structure, and each layer except the physical layer has its corresponding packet structure. From the link layer to the application layer, each layer encapsulates the packet from the next layer, so we design our data structures in a similar nested fashion. The basic construction method is as follows:

[packet_test.go](https://github.com/beardnick/lab/blob/62e2f4efaff1211860bdb3ea14d0006e7804f56a/network/netstack/tcpip/packet_test.go#L85)
```go
pack := NewIPPack(NewTcpPack(&RawPack{}))
```

The IP object wraps the TCP object, which wraps the raw object, resulting in an IP object. The constructor functions take interfaces as parameters, so if you want, you can even wrap another IP object inside the TCP object:

```go
pack := NewIPPack(NewTcpPack(NewIPPack(&RawPack{})))
```

This approach is not only theoretically possible but also practically meaningful. Some special network tools actually implement features like network proxying by wrapping raw data packets inside TCP.

The network packet interface is defined as follows:

[packet.go](https://github.com/beardnick/lab/blob/62e2f4efaff1211860bdb3ea14d0006e7804f56a/network/netstack/tcpip/packet.go#L3-L6)
```go
type NetworkPacket interface {
    Decode(data []byte) (NetworkPacket, error)
    Encode() ([]byte, error)
}
```

The constructor is defined as:

[tcp.go](https://github.com/beardnick/lab/blob/1213920ed1e5c48f8a6b028c49cae2490bbecd9e/network/netstack/tcpip/tcp.go#L62-L64)
```go
func NewTcpPack(payload NetworkPacket) *TcpPack {
    return &TcpPack{Payload: payload}
}
```

The network packet interface definition is very simple: the `Decode` function decodes data into an object, and the `Encode` function encodes an object into data.

# IP Packet Generation

Here's the complete implementation:

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

Most field conversions involve basic bit operations, which we won't explain in detail. The checksum generation needs attention.
Checksum calculation is a bit complicated and isn't a key focus of the TCP/IP protocol. If you want to quickly implement a working TCP/IP protocol, you can temporarily skip this part and just copy existing implementation code.
However, we can't ignore checksums entirely, as packets with invalid checksums will be discarded.

## Checksum

To calculate the checksum, we first generate the IP header data packet with the checksum field set to 0, then calculate the checksum on this data packet.
Here's the original text from the RFC:
[checksum](https://datatracker.ietf.org/doc/html/rfc1071#autoid-1)
```
In outline, the Internet checksum algorithm is very simple:
(1)  Adjacent octets to be checksummed are paired to form 16-bit
    integers, and the 1's complement sum of these 16-bit integers is
    formed.
```

Implementation:
```go
func calculateIPChecksum(headerData []byte) uint16 {
    if len(headerData)%2 == 1 {
        headerData = append(headerData, 0)
    }
    return ^OnesComplementSum(headerData)
}
```

# TCP Packet Generation

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

TCP packet generation is also only complex in terms of checksum calculation. Similarly, if you want to quickly implement a working TCP/IP protocol, you can temporarily skip this part and just copy existing implementation code.

## Checksum

TCP packet checksum calculation requires adding some extra data to the TCP header before calculating the checksum. Here's the original text from the RFC:

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

So we first need to generate the pseudo-header, then calculate the checksum. The pseudo-header data can be easily obtained from the IP packet. After generating the new packet, we can use the same function used for calculating IP checksums. Here's the final implementation:

[tcp checksum](https://github.com/beardnick/lab/blob/c030899077b98d44d8f750d8371befa457a87de0/network/netstack/tcpip/tcp.go#L143-L165)
```go
func (t *TcpPack) SetPseudoHeader(srcIP, dstIP []byte) {
    t.PseudoHeader = &PseudoHeader{SrcIP: srcIP, DstIP: dstIP}
}

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

# Checksum Calculation Performance Optimization

There are many ways to optimize checksum calculation. Here's one optimization method using uint32.
By using uint32 directly, all overflow parts are added to the high 16 bits. Then we add the high 16 bits back to the low 16 bits. If it overflows again, we continue adding back to the low 16 bits until there's no more overflow.

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

# Important Notes

- My TCP/IP stack project is primarily for educational purposes, so I prioritize code readability over performance. Many implementations are not optimal. Production-level code would include extensive performance optimizations, error handling, and boundary checks, sacrificing some readability for higher performance and security.
- In the current implementation, the IP ID is always 0 to simplify implementation. The IP ID is mainly used in IP fragmentation, so we can ignore it for now. The current implementation works fine for small packets.
- Both IP and TCP have options fields that involve some extended network functionality, which can also be ignored for initial implementation.

# Recommended Reading

- [General Network Packet Processing Library](https://github.com/google/gopacket)
- [Production-Level User-Space TCP/IP Stack Implementation](https://github.com/google/netstack)

# Summary

At this point, we have completed TCP packet generation. In the next article, we will start implementing the TCP three-way handshake. 