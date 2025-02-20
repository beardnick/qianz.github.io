# 自己动手编写tcp/ip协议栈4:tcp数据传输和四次挥手


# 数据传输

书接上回，连接建立成功后开始进行数据传输。

## 数据接收方

实现如下：

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

主要逻辑是：
- 如果收到的是ack包，则更新`sendUnack`为ack的序号，序号是否合法已经在外层的`checkSeqAck`中校验过了
- `recvNext`更新为`recvNext + len(data)`，这个值也是我们要回给发送方的ack号
- 数据通过`readCh`发送给上层`read()`接口，是一个异步发送的过程，如果`readCh`满了，则丢弃数据。这里利用了channel的特性实现了简单的接收缓冲区。

相应的读取到数据后可以通过上层`read()`接口获取到数据。
`read()`接口的实现如下：

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

主要逻辑是：
- 如果没有数据到来就会阻塞等待
- 如果连接关闭了，就会返回`io.EOF`

## 数据发送方 

实现如下：

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

主要逻辑是：
- 外层`send`负责加锁、发送数据包，内层`handleSend`负责构建数据包，这样拆分是为了让`handleSend`更方便进行单元测试
- 发送数据前先把数据放入发送缓冲区中，`cacheSendData`会根据滑动窗口的算法来决定发送多少数据
- 根据发送的数据量更新`sendUnack`和`sendNext`

滑动窗口是使用`sendNext`和`sendUnack`来实现了一个简单的环形缓冲区，`sendBufferRemain`函数返回缓冲区中剩余的空间大小。
缓冲区中未ack的数据可以在超时未收到对方ack后进行重传，重传还没有实现。
实现如下：

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

# 四次挥手

## 被动关闭处理fin

实现如下：

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

主要逻辑是：
- `recvNext`加1，因为fin占用一个序号，而`sendNext`没有加1，因为我们还没有发送fin
- 更新状态为`tcpip.TcpStateCloseWait`
- 返回ack，表示收到fin请求，但是不发送fin，表示还不能直接关闭连接
- 关闭`readCh`，表示不再接收数据，此时全双工的通道变成了半双工的通道，也就是半关闭状态了，不能再读数据了，但是可以写数据

那么问题来了，不能读数据了，那如何通知到上层的接口层呢？回想一下上面的`read()`接口，如果`readCh`关闭了，再读channel，channel返回的ok就为false了，然后就会返回一个`io.EOF`。

## `close()`

大家有没有想过所谓`CloseWait`状态，等待的是谁的close呢？是对方的close吗？但是对方不是已经发送了fin告诉我们要close了吗？答案是等待上层应用层的close。也就是等待上层调用`close()`接口。

实现如下：

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

主要逻辑是：
- 外层`Close()`接口负责加锁、发送关闭请求, 内层`passiveCloseSocket()`负责构建关闭请求包
- 更新状态为`TcpStateLastAck`
- 发送fin给对方，表示自己已经没有数据要发送了，等待对方关闭连接
- `sendNext`加1，因为我们发送了fin，fin占用一个序号

## 被动关闭时处理最后一个ack

实现如下：

[handleLastAck](https://github.com/beardnick/lab/blob/0bf3c23fb26a1d1173863a6f1b272e4fe9805011/network/netstack/socket/socket.go#L372-L376)
```go
func (s *TcpSocket) handleLastAck() {
	s.State = tcpip.TcpStateClosed
	s.network.removeSocket(s.fd)
	s.network.unbindSocket(s.SocketAddr)
}
```

主要逻辑是：
- 更新状态为`TcpStateClosed`
- 从`Network`中删除socket, 解绑socket和ip端口

## 主动关闭

实现如下：

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

主要逻辑是：
- 更新状态为`TcpStateFinWait1`
- `sendNext`加1，因为我们发送了fin，fin占用一个序号

## 主动关闭时处理ack

实现如下：

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

主要逻辑是：
- 如果收到的是ack包，则更新状态为`TcpStateFinWait2`
- 如果`tcpPack.AckNumber == s.sendNext-1`，则更新状态为`TcpStateFinWait2`，这种情况下没有数据传过来，不用处理数据。如果`tcpPack.AckNumber > s.sendNext-1`，则除了ack我们的fin，还传来了数据，也需要更新状态为`TcpStateFinWait2`，并且处理数据，所以此逻辑一并放在`handleFinWait2Fin`中

## 主动关闭后处理剩余数据

实现如下：

[handleFinWait2Fin](https://github.com/beardnick/lab/blob/0bf3c23fb26a1d1173863a6f1b272e4fe9805011/network/netstack/socket/socket.go#L390-L426)
```go
func (s *TcpSocket) handleFinWait2Fin(tcpPack *tcpip.TcpPack) (resp *tcpip.IPPack, err error) {
	if tcpPack.Flags&uint8(tcpip.TcpFIN) == 0 {
		return s.handleData(tcpPack)
	}
	...
}
```

主要逻辑是：
- 如果没有收到`fin`则只需要处理数据，处理数据可以直接复用`handleData`的逻辑

不怎么与posix api直接打交道的同学可能就会问了，我客户端主动调用`Close()`之后怎么再处理对方的数据呀？我好像从来没有这样处理过。
答案就是经过各种框架层层包装之后，这种接口并没有暴露出来，想要实现这个功能需要直接使用底层接口`shutdown()`。
在Go语言中需要调用`unix.Shutdown(conn, unix.SHUT_WR)`，这样会只关闭客户端的写通道，然后客户端还是可以读取数据的。

## 主动关闭后处理fin

实现如下：

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

主要逻辑是：
- 同时收到了数据和fin包，那么`recvNext`需要更新为`recvNext + len(data) + 1`，因为fin占用一个序号
- 将数据放入`readCh`中，等待上层读取
- 更新状态为`TcpStateClosed`，按照协议这里需要更新为`TimeWait`，但是这里没有实现，直接更新为`Closed`
- 清理socket和channel

# 总结

至此，简单的tcp/ip协议栈的实现就完成了。作为一个玩具实现，它已经可以与其它tcp/ip协议栈进行通信了。
项目加上测试代码共2000多行，还是比较易读的，可以作为学习tcp/ip协议栈的参考。自己写过一遍之后，tcp/ip协议栈对你来说就不那么神秘了。
之后如果有机会还会继续实现拥塞控制、重传、syn cookie等算法，到时候再分享给大家。
再次欢迎大家star我的实验项目[lab](https://github.com/beardnick/lab)，关注我的github page[千舟](https://beardnick.github.io/qianz.github.io/zh-cn/)。
