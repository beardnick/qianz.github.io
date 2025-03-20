---
title: "Write TCP/IP Stack by Yourself (3): TCP Three-Way Handshake"
date: 2025-02-19T09:56:13+08:00
---

# Data Structures

The main data structures of the project and their interactions are shown in the following diagram:

![netstack_datastructure](https://raw.githubusercontent.com/beardnick/static/master/images20250219120508.png)

- Dotted arrows represent asynchronous calls, implemented using Go's channel mechanism. If you want to implement this in another language, you'll need to use a thread-safe message queue to replace the channels.
- `Network` is mainly responsible for reading data packets from TUN, writing to TUN, binding socket and IP port information, and routing network packets to the appropriate socket for processing based on IP port information.
- `Socket` implements TCP protocol's connection management, data sending and receiving.
- When you send a SYN request to TUN, the data packet flow is: `tun -> Network -> Socket(handle syn) -> Socket(send syn ack) -> Network -> tun`
- After the connection is established, when sending data through the write interface, the packet flow is: `Socket(send data) -> Network -> tun`

# Three-Way Handshake and Four-Way Handshake

You might find that the three-way handshake and four-way handshake processes are easy to forget, and the details during the handshake are unclear. Here's a simple approach to help you understand the handshake process.
In my understanding, there are two key points in TCP design:

- Every sent data message requires an ACK response from the other party. This includes data packets, SYN, FIN, etc.
- TCP connections are full-duplex, so establishing a connection requires both parties to confirm receiving the other's information. A connection with only one party confirming is an intermediate state, called a half-open or half-closed connection.

Understanding these two points, you'll see that the three-way handshake and four-way handshake processes are actually identical, just that the handshake sends SYN while the closing process sends FIN. It looks like this:

![handshake](https://raw.githubusercontent.com/beardnick/static/master/images20250219130716.png)

You might wonder, wouldn't this make the three-way handshake into a four-way handshake? This is because the designers combined the server's SYN and ACK packets into one packet to improve performance, turning it into a three-way handshake.
During connection termination, the server might still have data to send, so it can't combine FIN and ACK, resulting in a four-way handshake. The final process looks like this:

![real_handshake](https://raw.githubusercontent.com/beardnick/static/master/images20250219130840.png)

# Sequence and Acknowledgment Number Calculation

Sequence and acknowledgment numbers are another challenging aspect of the TCP protocol. In my understanding, you only need to remember one point:

- All individual data messages occupy one sequence number and one acknowledgment number. Data messages include data packets, SYN, FIN, etc.

For example:
- During the three-way handshake, after sending the first SYN, the SYN occupies one sequence number, so the next packet from the client must use seq+1 as the sequence number. This means the first data packet's sequence number must be the initial sequence number plus 1.
- During the four-way handshake, after sending the first FIN, the FIN occupies one sequence number, so the next packet from the client must use seq+1 as the sequence number. For the server, after receiving FIN, if it only sends an ACK (ACK is not a data message), then the server's next packet will still use the current sequence number, no need to add 1.
- For data packets, each byte of data occupies one sequence number. If you send n bytes, the subsequent sequence number increases by n.

The acknowledgment number can be remembered in relation to the sequence number, simply as **the next sequence number the other party should send**. So calculating the acknowledgment number becomes calculating what sequence number the peer should send.

# Relationship between Send Window, Receive Window, and Sequence/Acknowledgment Numbers

Understanding sequence and acknowledgment numbers is crucial for understanding the sliding window. Here are the sliding window parameters defined in the RFC:

```txt
SND.UNA send unacknowledged
SND.NXT send next
RCV.NXT receive next
```

Translated:

- SND.UNA: The sequence number of sent but unacknowledged data
- SND.NXT: The next sequence number to send, all data before this number has been sent
- RCV.NXT: The next sequence number to receive, all data before this number has been received

Looking at our earlier analysis of sequence and acknowledgment numbers, SND.NXT is our next sequence number to send, and RCV.NXT is the acknowledgment number. Let's look at a diagram:

![tcp_window](https://raw.githubusercontent.com/beardnick/static/master/images20250219155820.png)

Notice that I've included SYN and FIN in the data boxes. Although they're not real data, they occupy sequence numbers, so including them in the data boxes makes it easier to understand.
Looking at the diagram, we can calculate the sequence and acknowledgment numbers the other party should send. Our acknowledgment number is **the next sequence number the other party should send**, and the other party's acknowledgment number is **the next sequence number we should send**.
However, the other party might not have received all our data, so their acknowledgment number might be smaller than our SND.NXT, it's a range. The other party shouldn't acknowledge the same data repeatedly, so their acknowledgment number range is `(SND.UNA, SND.NXT]`.
Note it's greater than `SND.UNA` because the acknowledgment is the next sequence number to send.

# `socket()`

The `socket()` interface creates a socket object. Currently, we can only create TCP sockets, while the Linux kernel can create sockets for UDP and other protocols.
Here's the socket object implementation:

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

Key fields to note:

- synQueue: The famous half-connection queue, used to store sockets that have received SYN but not ACK packets. Interestingly, it's a `map` here
- acceptQueue: The famous full-connection queue, used to store sockets with established connections. Here it's a `channel` for asynchronously passing `socket` to the `accept` interface
- recvNext: Next sequence number to receive
- sendNext: Next sequence number to send
- sendUnack: Sequence number of sent but unacknowledged data
- sendBuffer: Send buffer for storing data to be sent

## Half-Connection Queue

The name suggests it should be a queue, but thinking carefully, half-connections don't receive the third handshake in first-in-first-out order, so why would it be a queue? Moreover, to find which half-connection received the third handshake, we clearly should use a map for storage.
I once tried to find the half-connection queue implementation in the Linux kernel source code, but the kernel code was convoluted with no explicit `syn queue`. It was quite confusing until I found the answer on Stack Overflow:
[confusion-about-syn-queue-and-accept-queue](https://stackoverflow.com/questions/63232891/confusion-about-syn-queue-and-accept-queue).
In short, the kernel doesn't have an explicit half-connection queue data structure. The functionality is carried by a hash table called `ehash`, which isn't specifically designed for half-connections and has other functions.
The full-connection queue does have a dedicated variable `icsk_accept_queue`.

# `bind()`

The `bind()` interface binds a socket to a specified IP and port, specifically using a map in `Network` to associate `SocketAddr` with `TcpSocket`.

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

The socket retrieval method is quite sophisticated. The logic is:

1. First try to get the socket with key `[localIP, localPort, remoteIP, remotePort]`. If successful, it's either an established connection or a socket that initiated the connection
2. If not found, try with key `[localIP, localPort]`. This would be a listening socket
3. If not found, try with key `[localPort]`. This would be a socket listening on `0.0.0.0`

I haven't implemented the third logic, but it's straightforward to do so. Using this technique, our bind can handle all types of sockets flexibly.

# `listen()`

The `listen()` interface sets the socket to listening state. Implementation:

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

Main logic:
- Initialize socket data, note that `acceptQueue`'s length is `min(backlog, s.network.opt.SoMaxConn)`
- Start a goroutine (other languages would use threads, processes, or other concurrency mechanisms) to monitor `writeCh`. When data arrives (from `Network` reading from `Tun`), call the `handle` function to process it
- `handle` is responsible for locking, calling `handleState` to generate response packets, then passing response packets to `Network`

The design of `handle` and `handleState` functions is worth mentioning:

- The internal processing of `handleState` is very pure, not involving locks, channels, or other complex concurrency mechanisms. This pure logic is preserved for easy unit testing. Ideally, `handleState` should be side-effect free, only returning results based on input parameters (called a pure function).
- Putting the lock at the outermost layer also makes the logic clearer, otherwise it's very easy to cause deadlocks, data races, and other concurrency issues.

# Three-Way Handshake

Actually, implementing a usable three-way handshake and four-way handshake process just requires understanding sequence and acknowledgment number calculation, and send/receive window calculation. With the above foundation, implementation becomes relatively straightforward.
The protocol handling entry point is written like this:

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

The entry point is quite straightforward, just two big `switch` statements that call different handling functions based on the current connection state. Let's analyze these handling functions one by one.

## Handling SYN Packet in Passive Open

Since there's no socket listening on [localIP, localPort, remoteIP, remotePort] when the SYN packet arrives, the SYN packet is handled by the socket listening on [localIP, localPort].
The handling logic is:

[handleNewSocket](https://github.com/beardnick/lab/blob/6365a837db2e19f3027e776692817eab51a01ad6/network/netstack/socket/socket.go#L210-L229)
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

Main logic:
- Verify sequence and acknowledgment numbers are correct. This is a common logic placed in the `checkSeqAck` function
- Set connection state to `tcpip.TcpStateEstablished`
- Set `sendUnack` to the peer's acknowledgment number, as the peer sent ACK indicating they received the SYN
- Remove current socket from `synQueue`
- Add current socket to `acceptQueue` as the connection is established. If `acceptQueue` is full, drop the connection and return directly
- Add current socket to `Network`, listening on address `[localIP, localPort, remoteIP, remotePort]`. This address takes precedence over the listener's `[localIP, localPort]`, so subsequent requests will be handled by the current socket

## `connect()`

This is actively opening a connection. Implementation:

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

Main logic:
- Bind socket to `[localIP, localPort, remoteIP, remotePort]`. If `localIP` and `localPort` were specified during bind, use those; otherwise use randomly allocated ones from `Network`
- Initialize socket, setting itself as its own `listener`

Let's look at the `Socket.connect()` function:

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

Main logic:
- Set connection state to `tcpip.TcpStateSynSent`
- Send SYN packet
- Block to get a socket from `acceptQueue`. The socket obtained will be the current socket, with the listener being the socket itself. The current socket listens on `[localIP, localPort, remoteIP, remotePort]`, there will only be one socket

Other logic is the same as handling SYN packet in passive open, as they are symmetric.

## Handling SYN+ACK Packet in Active Open

Implementation:
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

Main logic:
- Verify it must be SYN+ACK packet
- Verify acknowledgment number is correct. Since only SYN was sent, acknowledgment number must be `sendUnack+1`
- Set connection state to `tcpip.TcpStateEstablished`
- Set `recvNext` to peer's sequence number plus 1, as peer's SYN occupies one sequence number
- Set `sendUnack` plus 1, as peer sent ACK indicating they received the SYN
- `sendNext` doesn't change as we only sent ACK, no data sent

# `accept()`

The accept function simply blocks to get a socket from `acceptQueue`, very simple implementation:

[Accept](https://github.com/beardnick/lab/blob/6365a837db2e19f3027e776692817eab51a01ad6/network/netstack/socket/socket.go#L78-L83)
```go
func (s *TcpSocket) Accept() (cfd int, addr SocketAddr, err error) {
    cs := <-s.acceptQueue
    cs.Lock()
    defer cs.Unlock()
    return cs.fd, cs.SocketAddr, nil
}
```

# Summary

Finally, we've covered the three-way handshake. The three-way handshake has many details, but understanding sequence and acknowledgment numbers, and send/receive window calculation makes it relatively easy to understand.
My implementation is just a toy implementation of the three-way handshake. Production-level implementations are much more complex.
There are also many valuable topics in this article that we haven't expanded on, such as how thread safety is implemented and how to make the code more testable. I'll discuss these in separate articles later.
If you found this article helpful, please give it a like and follow me. Feel free to point out any errors. Also welcome to star my experimental project [lab](https://github.com/beardnick/lab) and follow my GitHub page [千舟](https://beardnick.github.io/qianz.github.io/zh-cn/). 