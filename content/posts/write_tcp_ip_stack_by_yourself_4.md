---
title: "Write TCP/IP Stack by Yourself (4): TCP Data Transfer and Four-Way Handshake"
date: 2025-02-20T12:22:43+08:00
---

# Data Transfer

Continuing from the previous article, after the connection is established, we begin data transfer.

## Data Receiver

Here's the implementation:

[handleData](https://github.com/beardnick/lab/blob/6365a837db2e19f3027e776692817eab51a01ad6/network/netstack/socket/socket.go#L319-L352)
```go
func (s *TcpSocket) handleData(tcpPack *tcpip.TcpPack) (resp *tcpip.IPPack, err error) {
    if tcpPack.Flags&uint8(tcpip.TcpACK) != 0 {
        s.sendUnack = tcpPack.AckNumber
    }
    if tcpPack.Payload == nil {
        return nil, nil
    }
    data, err := tcpPack.Payload.Encode()
    if err != nil {
        return nil, fmt.Errorf("encode tcp payload failed %w", err)
    }
    if len(data) == 0 {
        return nil, nil
    }
    s.recvNext = s.recvNext + uint32(len(data))

    select {
    case s.readCh <- data:
    default:
        return nil, fmt.Errorf("the reader queue is full, drop the data")
    }

    ipResp, _, err := NewPacketBuilder(s.network.opt).
        SetAddr(s.SocketAddr).
        SetSeq(s.sendNext).
        SetAck(s.recvNext).
        SetFlags(tcpip.TcpACK).
        Build()
    if err != nil {
        return nil, err
    }

    return ipResp, nil
}
```

The main logic is:
- If an ACK packet is received, update `sendUnack` to the ACK sequence number. The sequence number validity has already been checked in the outer `checkSeqAck`
- Update `recvNext` to `recvNext + len(data)`. This value is also the ACK number we'll send back to the sender
- Send data to the upper layer's `read()` interface through `readCh`. This is an asynchronous process. If `readCh` is full, the data is discarded. Here we use the channel's characteristics to implement a simple receive buffer.

After receiving data, it can be accessed through the upper layer's `read()` interface.
Here's the implementation of the `read()` interface:

[Read](https://github.com/beardnick/lab/blob/0bf3c23fb26a1d1173863a6f1b272e4fe9805011/network/netstack/socket/socket.go#L100-L111)
```go
func (s *TcpSocket) Read() (data []byte, err error) {
    s.Lock()
    if s.State == tcpip.TcpStateCloseWait {
        return nil, io.EOF
    }
    s.Unlock()
    data, ok := <-s.readCh
    if !ok {
        return nil, io.EOF
    }
    return data, nil
}
```

The main logic is:
- If no data has arrived, it blocks and waits
- If the connection is closed, it returns `io.EOF`

## Data Sender

Here's the implementation:

[send](https://github.com/beardnick/lab/blob/0bf3c23fb26a1d1173863a6f1b272e4fe9805011/network/netstack/socket/socket.go#L428-L444)
[handleSend](https://github.com/beardnick/lab/blob/0bf3c23fb26a1d1173863a6f1b272e4fe9805011/network/netstack/socket/socket.go#L512-L541)
```go
func (s *TcpSocket) send(data []byte) (n int, err error) {
    s.Lock()
    defer s.Unlock()
    send, resp, err := s.handleSend(data)
    if err != nil {
        return 0, err
    }
    if resp == nil {
        return 0, nil
    }
    respData, err := resp.Encode()
    if err != nil {
        return 0, err
    }
    s.network.writeCh <- respData
    return send, nil
}

func (s *TcpSocket) handleSend(data []byte) (send int, resp *tcpip.IPPack, err error) {
    if s.State != tcpip.TcpStateEstablished {
        return 0, nil, fmt.Errorf("connection not established")
    }
    length := len(data)
    if length == 0 {
        return 0, nil, nil
    }

    send = s.cacheSendData(data)
    if send == 0 {
        return 0, nil, nil
    }

    ipResp, _, err := NewPacketBuilder(s.network.opt).
        SetAddr(s.SocketAddr).
        SetSeq(s.sendNext).
        SetAck(s.recvNext).
        SetFlags(tcpip.TcpACK).
        SetPayload(tcpip.NewRawPack(data[:send])).
        Build()
    if err != nil {
        return 0, nil, err
    }

    s.sendUnack = s.sendNext
    s.sendNext = s.sendNext + uint32(send)

    return send, ipResp, nil
}
```

The main logic is:
- The outer `send` is responsible for locking and sending data packets, while the inner `handleSend` is responsible for building data packets. This separation makes `handleSend` easier to unit test
- Before sending data, put it in the send buffer. `cacheSendData` will decide how much data to send based on the sliding window algorithm
- Update `sendUnack` and `sendNext` based on the amount of data sent

The sliding window is implemented using `sendNext` and `sendUnack` to create a simple circular buffer. The `sendBufferRemain` function returns the remaining space in the buffer.
Unacknowledged data in the buffer can be retransmitted if no ACK is received after timeout, though retransmission is not yet implemented.
Here's the implementation:

[cacheSendData](https://github.com/beardnick/lab/blob/0bf3c23fb26a1d1173863a6f1b272e4fe9805011/network/netstack/socket/socket.go#L559-L581)
```go
func (s *TcpSocket) cacheSendData(data []byte) int {
    send := 0
    remain := s.sendBufferRemain()
    if len(data) > remain {
        send = remain
    } else {
        send = len(data)
    }
    for i := 0; i < send; i++ {
        s.sendBuffer[(int(s.sendNext)+i)%len(s.sendBuffer)] = data[i]
    }
    return send
}

func (s *TcpSocket) sendBufferRemain() int {
    // tail - 1 - head + 1
    tail := int(s.sendNext) % len(s.sendBuffer)
    head := int(s.sendUnack) % len(s.sendBuffer)
    if tail >= head {
        return len(s.sendBuffer) - (tail - head)
    }
    return head - tail
}
```

# Four-Way Handshake

## Handling FIN in Passive Close

Here's the implementation:

[handleFin](https://github.com/beardnick/lab/blob/0bf3c23fb26a1d1173863a6f1b272e4fe9805011/network/netstack/socket/socket.go#L354-L370)
```go
func (s *TcpSocket) handleFin() (resp *tcpip.IPPack, err error) {
    s.recvNext += 1
    s.State = tcpip.TcpStateCloseWait
    ipResp, _, err := NewPacketBuilder(s.network.opt).
        SetAddr(s.SocketAddr).
        SetSeq(s.sendNext).
        SetAck(s.recvNext).
        SetFlags(tcpip.TcpACK).
        Build()
    if err != nil {
        return nil, err
    }

    close(s.readCh)

    return ipResp, nil
}
```

The main logic is:
- Increment `recvNext` by 1 because FIN occupies one sequence number, while `sendNext` doesn't increment because we haven't sent FIN yet
- Update state to `tcpip.TcpStateCloseWait`
- Return ACK to indicate FIN request received, but don't send FIN, indicating we can't close the connection directly
- Close `readCh` to indicate we won't receive more data. At this point, the full-duplex channel becomes half-duplex, or half-closed. We can't read data anymore, but we can still write data

So how do we notify the upper layer interface that we can't read data? Remember the `read()` interface above - when `readCh` is closed, reading from the channel will return false for ok, leading to an `io.EOF` return.

## `close()`

Have you ever wondered what the "Wait" in `CloseWait` state is waiting for? Is it waiting for the peer's close? But hasn't the peer already sent FIN to tell us they want to close? The answer is it's waiting for the application layer's close. That is, waiting for the upper layer to call the `close()` interface.

Here's the implementation:

[Close](https://github.com/beardnick/lab/blob/0bf3c23fb26a1d1173863a6f1b272e4fe9805011/network/netstack/socket/socket.go#L446-L472)
[PassiveCloseSocket](https://github.com/beardnick/lab/blob/0bf3c23fb26a1d1173863a6f1b272e4fe9805011/network/netstack/socket/socket.go#L474-L491)
```go
func (s *TcpSocket) Close() error {
    var (
        ipResp *tcpip.IPPack
        err    error
    )
    s.Lock()
    defer s.Unlock()
    if s.State == tcpip.TcpStateCloseWait {
        ipResp, err = s.passiveCloseSocket()
    } else if s.State == tcpip.TcpStateEstablished {
        ipResp, err = s.activeCloseSocket()
    } else {
        return fmt.Errorf("wrong state %s", s.State.String())
    }
    if err != nil {
        return err
    }

    data, err := ipResp.Encode()
    if err != nil {
        return err
    }

    s.network.writeCh <- data

    return nil
}

func (s *TcpSocket) passiveCloseSocket() (ipResp *tcpip.IPPack, err error) {
    s.State = tcpip.TcpStateLastAck

    ipResp, tcpResp, err := NewPacketBuilder(s.network.opt).
        SetAddr(s.SocketAddr).
        SetSeq(s.sendNext).
        SetAck(s.recvNext).
        SetFlags(tcpip.TcpFIN | tcpip.TcpACK).
        Build()
    if err != nil {
        return nil, err
    }

    s.sendUnack = tcpResp.SequenceNumber
    s.sendNext = tcpResp.SequenceNumber + 1

    return ipResp, nil
}
```

The main logic is:
- The outer `Close()` interface handles locking and sending close requests, while the inner `passiveCloseSocket()` handles building close request packets
- Update state to `TcpStateLastAck`
- Send FIN to peer, indicating we have no more data to send, waiting for peer to close connection
- Increment `sendNext` by 1 because we sent FIN, which occupies one sequence number

## Handling Last ACK in Passive Close

Here's the implementation:

[handleLastAck](https://github.com/beardnick/lab/blob/0bf3c23fb26a1d1173863a6f1b272e4fe9805011/network/netstack/socket/socket.go#L372-L376)
```go
func (s *TcpSocket) handleLastAck() {
    s.State = tcpip.TcpStateClosed
    s.network.removeSocket(s.fd)
    s.network.unbindSocket(s.SocketAddr)
}
```

The main logic is:
- Update state to `TcpStateClosed`
- Remove socket from `Network` and unbind socket from IP port

## Active Close

Here's the implementation:

[ActiveCloseSocket](https://github.com/beardnick/lab/blob/0bf3c23fb26a1d1173863a6f1b272e4fe9805011/network/netstack/socket/socket.go#L493-L510)
```go
func (s *TcpSocket) activeCloseSocket() (ipResp *tcpip.IPPack, err error) {
    s.State = tcpip.TcpStateFinWait1

    ipResp, tcpResp, err := NewPacketBuilder(s.network.opt).
        SetAddr(s.SocketAddr).
        SetSeq(s.sendNext).
        SetAck(s.recvNext).
        SetFlags(tcpip.TcpFIN | tcpip.TcpACK).
        Build()
    if err != nil {
        return nil, err
    }

    s.sendUnack = tcpResp.SequenceNumber
    s.sendNext = tcpResp.SequenceNumber + 1

    return ipResp, nil
}
```

The main logic is:
- Update state to `TcpStateFinWait1`
- Increment `sendNext` by 1 because we sent FIN, which occupies one sequence number

## Handling ACK in Active Close

Here's the implementation:

[handleFinWait1](https://github.com/beardnick/lab/blob/0bf3c23fb26a1d1173863a6f1b272e4fe9805011/network/netstack/socket/socket.go#L378-L388)
```go
func (s *TcpSocket) handleFinWait1(
    tcpPack *tcpip.TcpPack,
) (resp *tcpip.IPPack, err error) {
    if tcpPack.Flags&uint8(tcpip.TcpACK) == 0 {
        return nil, fmt.Errorf("invalid packet, ack flag isn't set %s", tcpip.InspectFlags(tcpPack.Flags))
    }
    if tcpPack.AckNumber >= s.sendNext-1 {
        s.State = tcpip.TcpStateFinWait2
    }
    return s.handleFinWait2Fin(tcpPack)
}
```    

The main logic is:
- If an ACK packet is received, update state to `TcpStateFinWait2`
- If `tcpPack.AckNumber == s.sendNext-1`, update state to `TcpStateFinWait2`. In this case, no data came through, so no need to handle data. If `tcpPack.AckNumber > s.sendNext-1`, besides acknowledging our FIN, data also came through, so we still need to update state to `TcpStateFinWait2` and handle the data, so this logic is combined in `handleFinWait2Fin`

## Handling Remaining Data in Active Close

Here's the implementation:

[handleFinWait2Fin](https://github.com/beardnick/lab/blob/0bf3c23fb26a1d1173863a6f1b272e4fe9805011/network/netstack/socket/socket.go#L390-L426)
```go
func (s *TcpSocket) handleFinWait2Fin(tcpPack *tcpip.TcpPack) (resp *tcpip.IPPack, err error) {
    if tcpPack.Flags&uint8(tcpip.TcpFIN) == 0 {
        return s.handleData(tcpPack)
    }
    ...
}
```

The main logic is:
- If no `FIN` is received, just handle the data. Data handling can directly reuse the `handleData` logic

Those who don't directly work with POSIX APIs might ask, how can I handle peer data after the client actively calls `Close()`? I don't seem to have ever handled it this way.
The answer is that after layers of framework wrapping, this interface isn't exposed. To implement this functionality, you need to use the lower-level `shutdown()` interface.
In Go, you need to call `unix.Shutdown(conn, unix.SHUT_WR)`. This will only close the client's write channel, and the client can still read data.

## Handling FIN in Active Close

Here's the implementation:

[handleFinWait2Fin](https://github.com/beardnick/lab/blob/93f64fcea7de99859111cad68693402dad97f173/network/netstack/socket/socket.go#L390-L427)
```go
func (s *TcpSocket) handleFinWait2Fin(tcpPack *tcpip.TcpPack) (resp *tcpip.IPPack, err error) {
    if tcpPack.Flags&uint8(tcpip.TcpFIN) == 0 {
        return s.handleData(tcpPack)
    }

    s.sendUnack = tcpPack.AckNumber
    data, err := tcpPack.Payload.Encode()
    if err != nil {
        return nil, fmt.Errorf("encode tcp payload failed %w", err)
    }

    // +1 for FIN
    s.recvNext = s.recvNext + uint32(len(data)) + 1

    if len(data) > 0 {
        select {
        case s.readCh <- data:
        default:
            return nil, fmt.Errorf("the reader queue is full, drop the data")
        }
    }

    ipResp, _, err := NewPacketBuilder(s.network.opt).
        SetAddr(s.SocketAddr).
        SetSeq(s.sendNext).
        SetAck(s.recvNext).
        SetFlags(tcpip.TcpACK).
        Build()
    if err != nil {
        return nil, err
    }

    s.State = tcpip.TcpStateClosed
    s.network.removeSocket(s.fd)
    s.network.unbindSocket(s.SocketAddr)
    close(s.readCh)
    return ipResp, nil
}
```

The main logic is:
- If both data and FIN packet are received, then `recvNext` needs to be updated to `recvNext + len(data) + 1`, because FIN occupies one sequence number
- Put data into `readCh` for upper layer to read
- Update state to `TcpStateClosed`. According to the protocol, this should be updated to `TimeWait`, but we haven't implemented that, so directly update to `Closed`
- Clean up socket and channel

# Summary

At this point, we've completed the implementation of a simple TCP/IP stack. As a toy implementation, it can already communicate with other TCP/IP stacks.
The project, including test code, is about 2,000 lines and is quite readable. It can serve as a reference for learning TCP/IP stack. After writing it yourself, the TCP/IP stack won't seem so mysterious anymore.
If there's a chance later, I'll continue to implement congestion control, retransmission, SYN cookie, and other algorithms, and share them with everyone.
Again, welcome to star my experimental project [lab](https://github.com/beardnick/lab) and follow my GitHub page [qianz](https://beardnick.github.io/qianz.github.io/). 