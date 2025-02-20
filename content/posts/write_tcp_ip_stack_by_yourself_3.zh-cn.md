---
title: "自己动手编写tcp/ip协议栈3:tcp三次握手"
date: 2025-02-19T09:56:13+08:00
---

# 数据结构

项目的主要数据结构及其交互方式如下图

![netstack_datastructure](https://raw.githubusercontent.com/beardnick/static/master/images20250219120508.png)

- 虚线的箭头表示是异步调用，这里使用的是Go中的channel机制实现的。如果你想要使用其语言实现需要使用一种并发安全的消息队列替换这里的channel。
- `NewWork`主要负责读取tun中的数据包，向tun写入数据，绑定socket和ip端口信息，根据ip端口信息将相应的网络包发给相应的socket处理。
- `Socket`实现了tcp协议的连接管理，数据发送和接收。
- 当你发送一个syn请求到tun时数据包的流向为：`tun -> NewWork -> Socket(handle syn) -> Socket(send syn ack) -> Network -> tun`
- 当连接建立后，通过write接口发送数据时包的流向为：`Socket(send data) -> Network -> tun`

# 三次握手和四次挥手

大家可能会觉得三次握手、四次挥手的过程总是背了又忘，握手期间的各种细节也记不清楚。我这里提供一个简单的思路，帮助大家理解三次握手的过程。
我理解上tcp设计上有两个重点：

- 每个发送的数据信息都要求对方有一个ack响应，这里的数据信息包括数据包、syn、fin等。
- tcp的连接是全双工的，所以一个连接的建立需要双方都确认收到了对方的信息。只有一方确认的是中间状态，称为半开连接或半关连接。

理解了这两点，再看一下三次握手和四次挥手的流程其实是完全相同的，只不过握手过程发送的是syn，挥手过程发送的是fin。就是下面这样：

![handshake](https://raw.githubusercontent.com/beardnick/static/master/images20250219130716.png)

那么问题就来了，那三次握手不就变成四次握手了吗？这是因为设计者为了提高性能将server端发回的syn和ack两个包合并成了一个包，所以就变成了三次握手。
而连接断开过程中server端可能还有数据要发送，所以不能将syn和ack合并，所以就变成了四次挥手。最终的流程就变成了这样：

![real_handshake](https://raw.githubusercontent.com/beardnick/static/master/images20250219130840.png)

# seq号和ack号计算

seq号和ack号也是tcp协议中一个记忆的难点。在我的理解来看，只需要记住一个点：

- 所有单个数据信息都要占用一个seq号，同时占用一个ack号 ，数据信息包括数据包、syn、fin等。

举例来说：
- 在三次握手阶段，发送第一个syn之后，syn占用了一个seq号，那么下次client发送包时就要使用seq+1作为seq号。也就是第一个数据包的seq号一定是初始seq号加1。
- 在四次挥手阶段，发送第一个fin之后，fin占用了一个seq号，那么下次client发送包时就要使用seq+1作为seq号。而作为server端，在收到fin之后，如果只发送了一个ack，ack不是数据信息，那么server端下次发送的包的seq号就还是当前seq号，不用加一。
- 如果是数据包，一个字节数据占用一个seq号，发送了几个字节，在之后seq号就加几。

而ack号的记忆就根据seq号来，直接把ack号记忆为**下一个对方应该发送的seq号**。那么计算ack号就转换成了计算对端应该发送的seq号。

# 发送窗口、接收窗口和seq号、ack号的关系

seq号和ack号的理解对于我们理解滑动窗口非常重要。这是rfc中定义的滑动窗口的参数：

```txt
SND.UNA	send unacknowledged
SND.NXT	send next
RCV.NXT	receive next
```

翻译过来就是

- SND.UNA：发送了但是未确认的seq号
- SND.NXT：下一个要发送的seq号，这个号之前的数据都已经发送过了
- RCV.NXT：下一个要接收的seq号，这个号之前的数据都已经接收过了

和我们在上面对seq和ack的分析来看，SND.NXT就是我们这一方下一个要发送的seq号，而RCV.NXT就是ack号。我们画一个图看一下：

![tcp_window](https://raw.githubusercontent.com/beardnick/static/master/images20250219155820.png)

注意到，我把syn,fin也都画入数据的格子中了，虽然syn,fin并非真实的数据，但是因为它们要占用seq号，所以把它们画入数据格子中更方便理解。
通过看图，我们也可以把对方应该发送的seq号和ack号计算出来。我们发的ack号就是**下一个对方应该发送的seq号**，而对方发送的ack号就是**下一个我们应该发送的seq号**，
不过对方可能没有收到我们的所有数据，所以对方发送的ack号可能比我们的SND.NXT要小，是一个范围。对方不应该重复ack相同的数据，所以对方发送的ack号范围就是`(SND.UNA, SND.NXT]`。
注意是大于`SND.UNA`，因为ack是下一个应该发送的seq号。

# `socket()`

`socket()`接口生成一个socket对象，现在我们只能生成一个tcp的socket，linux内核中的可以生成udp等其它协议的socket。
socket对象的实现如下：

[TcpSocket](https://github.com/beardnick/lab/blob/6365a837db2e19f3027e776692817eab51a01ad6/network/netstack/socket/socket.go#L13-L40)
```go
type SocketAddr struct {
	LocalIP    string
	RemoteIP   string
	LocalPort  uint16
	RemotePort uint16
}

type TcpSocket struct {
	sync.Mutex
	SocketAddr
	State tcpip.TcpState

	fd int

	network  *Network
	listener *TcpSocket

	acceptQueue chan *TcpSocket
	synQueue    sync.Map

	readCh  chan []byte
	writeCh chan *tcpip.IPPack

	recvNext   uint32
	sendNext   uint32
	sendUnack  uint32
	sendBuffer []byte
}
```	

主要注意这些字段

- synQueue：著名的半连接队列，用于存放收到syn包但还没有收到ack包的socket，有意思的是在这里它是一个`map`
- acceptQueue: 著名的全连接队列，用于存放已经建立连接的socket。这里使用的是一个`channel`，方便异步地将`socket`传给`accept`接口
- recvNext: 下一个要接收的seq号
- sendNext: 下一个要发送的seq号
- sendUnack: 发送了但是未确认的seq号
- sendBuffer: 发送缓冲区，用于存放待发送的数据

## 半连接队列

听这个名字这个应该是一个队列，但是仔细一想就会发现，半连接又不是按先进先出的顺序收到第三次握手的，为什么会是一个队列呢？而且因为要找到是哪个半连接收到了第三次握手，显然应该用一个map来存储。
我曾经在linux内核源码中尝试找到半连接队列的实现，但是内核代码绕来绕去，也没有一个叫`syn queue`的东西，令人十分迷惑，最终在stackoverflow上找到了答案
[confusion-about-syn-queue-and-accept-queue](https://stackoverflow.com/questions/63232891/confusion-about-syn-queue-and-accept-queue)。
长话短说就是内核中没有一个显式的半连接队列的数据结构，承载相关功能的是一个叫`ehash`的hash表，这个hash表也不是专门为半连接设计的，它还有其它功能。
全连接队列确实是有一个专门的变量`icsk_accept_queue`。

# `bind()`

`bind()`接口用于将socket绑定到指定的ip和端口上，具体来说是在`Network`中将`SocketAddr`和`TcpSocket`用map关联起来。

[bindSocket](https://github.com/beardnick/lab/blob/bda182aad77b7dc9890e73725b6d6957c436fad7/network/netstack/socket/net.go#L396-L398)
```go
func (n *Network) bindSocket(addr SocketAddr, fd int) {
	n.socketFds.Store(addr, fd)
}
```

[getSocket](https://github.com/beardnick/lab/blob/bda182aad77b7dc9890e73725b6d6957c436fad7/network/netstack/socket/net.go#L371-L385)
```go
func (n *Network) getSocket(addr SocketAddr) (sock *TcpSocket, ok bool) {
	value, ok := n.socketFds.Load(addr)
	if ok {
		return n.getSocketByFd(value.(int))
	}
	newAddr := SocketAddr{
		LocalIP:   addr.LocalIP,
		LocalPort: addr.LocalPort,
	}
	value, ok = n.socketFds.Load(newAddr)
	if ok {
		return n.getSocketByFd(value.(int))
	}
	return nil, false
}
```

获取socket的方法比较有讲究，具体逻辑是:

1. 先以`[localIP, localPort, remoteIP, remotePort]`为key获取socket，如果可以获取到的话，获取到的就是那种已经建立连接的，或者是那种主动发起连接的socket
2. 如果获取不到，则以`[localIP, localPort]`为key获取socket，获取到的就是那种`listen`的socket
3. 如果获取不到，则以`[localPort]`为key获取socket，获取到的就是那种`listen`了`0.0.0.0`的socket

第三条逻辑我没有实现，不过实现起来是完全没有难度的。利用这个技巧，我们的bind就可以bind所有的类型的socket了，非常灵活。

# `listen()`

`listen()`接口用于将socket设置为监听状态。实现如下：

```go
func (n *Network) listen(fd int, backlog uint) (err error) {
	sock, ok := n.getSocketByFd(fd)
	if !ok {
		return fmt.Errorf("%w: %d", ErrNoSocket, fd)
	}
	InitListenSocket(sock)
	return sock.Listen(backlog)
}

func InitListenSocket(sock *TcpSocket) {
	sock.Lock()
	defer sock.Unlock()
	sock.synQueue = sync.Map{}
	sock.readCh = make(chan []byte)
	sock.writeCh = make(chan *tcpip.IPPack)
	sock.State = tcpip.TcpStateListen
}

func (s *TcpSocket) Listen(backlog uint) (err error) {
	s.acceptQueue = make(chan *TcpSocket, min(backlog, s.network.opt.SoMaxConn))
	go s.runloop()
	return nil
}

func (s *TcpSocket) runloop() {
	for data := range s.writeCh {
		tcpPack := data.Payload.(*tcpip.TcpPack)
		s.handle(data, tcpPack)
	}
}

func (s *TcpSocket) handle(ipPack *tcpip.IPPack, tcpPack *tcpip.TcpPack) {
	s.Lock()
	defer s.Unlock()
	if s.network.opt.Debug {
		log.Printf(
			"before handle %s:%d => %s:%d %s",
			ipPack.SrcIP,
			tcpPack.SrcPort,
			ipPack.DstIP,
			tcpPack.DstPort,
			s.State.String(),
		)
	}
	resp, err := s.handleState(ipPack, tcpPack)
	if err != nil {
		log.Println(err)
		return
	}
	log.Printf(
		"after handle %s:%d => %s:%d %s",
		ipPack.SrcIP,
		tcpPack.SrcPort,
		ipPack.DstIP,
		tcpPack.DstPort,
		s.State.String(),
	)
	if resp == nil {
		return
	}
	data, err := resp.Encode()
	if err != nil {
		log.Println(err)
		return
	}
	s.network.writeCh <- data
}
```

主要逻辑是：
- 初始化`socket`的一些数据，注意`acceptQueue`的长度是`min(backlog, s.network.opt.SoMaxConn)`
- 启动一个`goroutine`(其它语言实现就用线程，进程之类的并发机制)，监听`writeCh`，当有数据(是`Network`从`Tun`中读取到然后传过来的数据)到来时，调用`handle`函数处理
- `handle`负责上锁，调用`handleState`函数生成响应包，然后由`handle`函数将响应包传给`Network`

这里`handle`和`handleState`函数的设计值得一提。

- `handleState`函数内部的处理十分纯粹，没有涉及到锁，`channel`等复杂的并发机制，保留这种存粹的逻辑是为了方便做单元测试。如果做得更好的话`handleState`需要不带副作用，只根据输入的参数返回结果(叫做纯函数)。
- 把锁放在最外层也让逻辑更加清晰，不然十分容易造成死锁，数据竞争等并发问题。

# 三次握手

其实想要实现一个可以使用的三次握手和四次挥手的过程就只需要搞清楚seq号和ack号的计算，以及发送窗口和接收窗口的计算。有了上面的基础，实现起来就相对来说比较轻松了。 
协议处理的入口是这样写的：

[socket.go#L196-L243](https://github.com/beardnick/lab/blob/253c47fe4ca605942c5980f9f11427facf5501ec/network/netstack/socket/socket.go#L196-L243)
```go
func (s *TcpSocket) handleState(ipPack *tcpip.IPPack, tcpPack *tcpip.TcpPack) (resp *tcpip.IPPack, err error) {
	switch s.State {
	case tcpip.TcpStateListen:
		s.handleNewSocket(ipPack, tcpPack)
	case tcpip.TcpStateSynSent:
		resp, err = s.handleSynResp(tcpPack)
	default:
		if !s.checkSeqAck(tcpPack) {
			return nil, fmt.Errorf(
				"seq %d or ack %d invalid recvNext %d sendUnack %d sendNext %d",
				tcpPack.SequenceNumber,
				tcpPack.AckNumber,
				s.recvNext,
				s.sendUnack,
				s.sendNext,
			)
		}
		switch s.State {
		case tcpip.TcpStateClosed:
			if tcpPack.Flags&uint8(tcpip.TcpSYN) != 0 {
				resp, err = s.handleSyn(tcpPack)
			}
		case tcpip.TcpStateSynReceived:
			if tcpPack.Flags&uint8(tcpip.TcpACK) != 0 {
				resp, err = s.handleFirstAck(tcpPack)
			}
		case tcpip.TcpStateEstablished:
			if tcpPack.Flags&uint8(tcpip.TcpFIN) != 0 {
				resp, err = s.handleFin()
				return
			}
			resp, err = s.handleData(tcpPack)
		case tcpip.TcpStateLastAck:
			if tcpPack.Flags&uint8(tcpip.TcpACK) != 0 {
				s.handleLastAck()
				return nil, nil
			}
		case tcpip.TcpStateCloseWait:
		case tcpip.TcpStateFinWait1:
			resp, err = s.handleFinWait1(tcpPack)
		case tcpip.TcpStateFinWait2:
			resp, err = s.handleFinWait2Fin(tcpPack)
		default:
			return nil, fmt.Errorf("invalid state %d", s.State)
		}
	}
	return resp, err
}
```

入口还比较直观，就是两个大的`switch`语句，根据当前连接的不同状态，然后调用不同的处理函数。接下来就一点点分析这些处理函数就行。


## 被动开启时处理syn包

由于syn包发送过来时还没有相应的监听了[localIP, localPort, remoteIP, remotePort]的socket，所以处理syn包的是监听了[localIP, localPort]的socket。
处理逻辑如下:

[handleNewSocket](https://github.com/beardnick/lab/blob/6365a837db2e19f3027e776692817eab51a01ad6/network/netstack/socket/socket.go#L210-L229)
```go
func (s *TcpSocket) handleNewSocket(ipPack *tcpip.IPPack, tcpPack *tcpip.TcpPack) {
	value, ok := s.synQueue.Load(tcpPack.SrcPort)
	var sock *TcpSocket
	if ok {
		sock = value.(*TcpSocket)
	} else {
		sock = NewSocket(s.network)
		InitConnectSocket(
			sock,
			s,
			SocketAddr{
				LocalIP:    ipPack.DstIP.String(),
				LocalPort:  tcpPack.DstPort,
				RemoteIP:   ipPack.SrcIP.String(),
				RemotePort: tcpPack.SrcPort,
			},
		)
	}
	sock.handle(ipPack, tcpPack)
}
```

如代码所示会先生成一个socket，状态为`tcpip.TcpStateClosed`，然后调用`handle`函数处理syn包，handle函数会再次走入`handleState`函数，然后调用`handleSyn`函数处理syn包。
当前当前的socket被保存在新socket的`listener`字段中，用于后续将自己加入到`listener.acceptQueue`中。

`handleSyn`实现如下：

[handleSyn](https://github.com/beardnick/lab/blob/253c47fe4ca605942c5980f9f11427facf5501ec/network/netstack/socket/socket.go#L266-L294)
```go
func (s *TcpSocket) handleSyn(tcpPack *tcpip.TcpPack) (resp *tcpip.IPPack, err error) {
	s.State = tcpip.TcpStateSynReceived
	s.recvNext = tcpPack.SequenceNumber + 1
	s.listener.synQueue.Store(tcpPack.SrcPort, s)

	var seq uint32
	if s.network.opt.Seq == 0 {
		seq = uint32(rand.Int())
	} else {
		seq = s.network.opt.Seq
	}

	s.sendUnack = seq
	s.sendNext = seq

	ipResp, _, err := NewPacketBuilder(s.network.opt).
		SetAddr(s.SocketAddr).
		SetSeq(s.sendNext).
		SetAck(s.recvNext).
		SetFlags(tcpip.TcpSYN | tcpip.TcpACK).
		Build()
	if err != nil {
		return nil, err
	}

	s.sendNext++

	return ipResp, nil
}
```

主要逻辑是:
- 将连接状态设置为`tcpip.TcpStateSynReceived`
- 将`recvNext`设置为对端发送的seq号加1，因为对方的syn占用一个对方的seq号
- 生成初始seq号，如果配置了初始seq号，则使用配置的seq号，否则使用随机数
- 将`sendUnack`设置为初始seq号，用于等待对方对这个`syn`进行ack。
- 将`sendNext`设置为初始seq号，用于发送下一个数据包的seq号，发送后`sendNext`加1，因为syn占用我们一个seq号
- 把当前socket加入到`synQueue`中，`synQueue`也就是半连接队列。

## 被动开启时处理ack包

实现如下：
```go
func (s *TcpSocket) handleFirstAck(tcpPack *tcpip.TcpPack) (resp *tcpip.IPPack, err error) {
	s.State = tcpip.TcpStateEstablished
	s.sendUnack = tcpPack.AckNumber
	s.synQueue.Delete(s.RemotePort)
	select {
	case s.listener.acceptQueue <- s:
	default:
		return nil, fmt.Errorf("accept queue is full, drop connection")
	}

	s.network.addSocket(s)
	s.network.bindSocket(s.SocketAddr, s.fd)
	go s.runloop()
	return nil, nil
}

func (s *TcpSocket) checkSeqAck(tcpPack *tcpip.TcpPack) (valid bool) {
	if s.State == tcpip.TcpStateClosed {
		return true
	}
	if tcpPack.SequenceNumber != s.recvNext {
		return false
	}
	if tcpPack.Flags&uint8(tcpip.TcpACK) == 0 {
		return true
	}
	if s.sendUnack == s.sendNext {
		return tcpPack.AckNumber == s.sendNext
	}
	return tcpPack.AckNumber > s.sendUnack && tcpPack.AckNumber <= s.sendNext
}
```

主要逻辑是：
- 校验seq号和ack号是否正确，这个逻辑是一个通用逻辑，放在了`checkSeqAck`函数中
- 将连接状态设置为`tcpip.TcpStateEstablished`
- 将`sendUnack`设置为对端发送的ack号，因为对端发送了ack，代表对端收到了syn
- 将当前socket从`synQueue`中删除
- 将当前socket加入到`acceptQueue`中，因为已经建立了连接，如果`acceptQueue`满了，则丢弃连接，直接返回
- 将当前socket加入到`Network`中，监听的地址是`[localIP, localPort, remoteIP, remotePort]`，这个地址优先于监听状态的listener监听的`[localIP, localPort]`，所以之后的请求会被当前socket处理

## `connect()`

也就是主动开启连接，实现如下：

[connect](https://github.com/beardnick/lab/blob/bda182aad77b7dc9890e73725b6d6957c436fad7/network/netstack/socket/net.go#L337-L369)
```go
func (n *Network) connect(fd int, serverAddr string) (err error) {
	serverIP, serverPort, err := parseAddress(serverAddr)
	if err != nil {
		return err
	}
	n.Lock()
	defer n.Unlock()
	sock, ok := n.getSocketByFd(fd)
	if !ok {
		return fmt.Errorf("%w: %d", ErrNoSocket, fd)
	}
	var addr SocketAddr
	if sock.LocalIP == "" && sock.LocalPort == 0 {
		addr, err = n.getAvailableAddress()
		if err != nil {
			return err
		}
	} else {
		n.unbindSocket(SocketAddr{
			LocalIP:   sock.LocalIP,
			LocalPort: sock.LocalPort,
		})
		addr = SocketAddr{
			LocalIP:   sock.LocalIP,
			LocalPort: sock.LocalPort,
		}
	}
	addr.RemoteIP = serverIP.String()
	addr.RemotePort = serverPort
	n.bindSocket(addr, fd)
	InitConnectSocket(sock, nil, addr)
	return sock.Connect()
}
```

主要逻辑是：
- 将socket绑定到`[localIP, localPort, remoteIP, remotePort]`，如果在bind的时候指定了`localIP`和`localPort`，则使用指定的，否则使用`Network`中随机分配的
- 初始化socket，将自己设置为自己的`listener`

继续看`Socket.connect()`函数，实现如下：

[connect](https://github.com/beardnick/lab/blob/6365a837db2e19f3027e776692817eab51a01ad6/network/netstack/socket/socket.go#L584-L628)
```go
func (s *TcpSocket) connect() (err error) {
	err = s.Listen(1)
	if err != nil {
		return err
	}
	ipResp, err := s.activeConnect()
	if err != nil {
		return err
	}
	data, err := ipResp.Encode()
	if err != nil {
		return err
	}
	s.network.writeCh <- data
	<-s.acceptQueue
	return nil
}

func (s *TcpSocket) activeConnect() (ipResp *tcpip.IPPack, err error) {
	s.State = tcpip.TcpStateSynSent
	var seq uint32
	if s.network.opt.Seq == 0 {
		seq = uint32(rand.Int())
	} else {
		seq = s.network.opt.Seq
	}

	s.sendUnack = seq
	s.sendNext = seq

	ipResp, _, err = NewPacketBuilder(s.network.opt).
		SetAddr(s.SocketAddr).
		SetSeq(s.sendNext).
		SetFlags(tcpip.TcpSYN).
		Build()
	if err != nil {
		return nil, err
	}

	s.sendNext++

	s.listener = s

	return ipResp, nil
}
```

主要逻辑是:
- 将连接状态设置为`tcpip.TcpStateSynSent`
- 发送syn包
- 阻塞地`acceptQueue`中获取一个socket，获取到的socket就是当前socket，listener是当前socket自己，当前socket监听了`[localIP, localPort, remoteIP, remotePort]`，只会有唯一一个socket

其它逻辑和被动开启时处理syn包的逻辑是相同的，因为它们是对称的。

## 主动开启时处理syn ack包

实现如下：
[handleSynResp](https://github.com/beardnick/lab/blob/6365a837db2e19f3027e776692817eab51a01ad6/network/netstack/socket/socket.go#L261-L301)
```go
func (s *TcpSocket) handleSynResp(tcpPack *tcpip.TcpPack) (resp *tcpip.IPPack, err error) {
	if tcpPack.Flags&uint8(tcpip.TcpACK) == 0 || tcpPack.Flags&uint8(tcpip.TcpSYN) == 0 {
		// syn + ack expected
		// just drop the packet
		return nil,
			fmt.Errorf(
				"invalid packet, expected syn and ack, but get %s",
				tcpip.InspectFlags(tcpPack.Flags),
			)
	}
	if tcpPack.AckNumber != s.sendUnack+1 {
		return nil,
			fmt.Errorf(
				"invalid packet, expected ack %d, but get %d",
				s.sendUnack,
				tcpPack.AckNumber,
			)
	}

	s.State = tcpip.TcpStateEstablished
	s.recvNext = tcpPack.SequenceNumber + 1

	ipResp, _, err := NewPacketBuilder(s.network.opt).
		SetAddr(s.SocketAddr).
		SetSeq(s.sendNext).
		SetAck(s.recvNext).
		SetFlags(tcpip.TcpACK).
		Build()
	if err != nil {
		return nil, err
	}
	s.sendUnack++

	select {
	case s.listener.acceptQueue <- s:
	default:
		return nil, fmt.Errorf("accept queue is full, drop connection")
	}

	return ipResp, nil
}
```

主要逻辑是:
- 校验一定是syn，ack包
- 校验ack号是否正确，因为只发送了syn，那么ack号一定是`sendUnack+1`
- 将连接状态设置为`tcpip.TcpStateEstablished`
- 将`recvNext`设置为对端发送的seq号加1，因为对方的syn占用一个对方的seq号
- 将`sendUnack`加1，因为对方发送了ack，代表对端收到了syn
- `sendNext`没有变化，因为我们这次只是发送了ack，没有发送数据

# `accept()`

accept函数是阻塞地从`acceptQueue`中获取一个socket，十分简单，实现如下：

[Accept](https://github.com/beardnick/lab/blob/6365a837db2e19f3027e776692817eab51a01ad6/network/netstack/socket/socket.go#L78-L83)
```go
func (s *TcpSocket) Accept() (cfd int, addr SocketAddr, err error) {
	cs := <-s.acceptQueue
	cs.Lock()
	defer cs.Unlock()
	return cs.fd, cs.SocketAddr, nil
}
```

# 总结

终于讲完了三次握手。三次握手有非常多的细节，但是理解了seq号和ack号，以及发送窗口和接收窗口的计算，理解起来就相对容易了。
我的实现也只是一个玩具型的三次握手实现，实际生产级别的实现要复杂得多。
这篇文章中也还有非常多十分值得学习的内容没有展开来讲，比如并发安全是如何实现的、如何让代码更加可测试，这些我之后都会单开文章来讲解。
如果觉得这篇文章对你有帮助，请点个赞，关注我，发现错误也请尽情指出。也欢迎star我的实验项目[lab](https://github.com/beardnick/lab)，关注我的github page[千舟](https://beardnick.github.io/qianz.github.io/zh-cn/)。