# write tcp/ip stack by yourself(1):tcp handshake and tuntap


# 1. simple way to understand tcp handshakes

you may find it hard to remember tcp three-way handshake and four-way handshake.\
Here I'll share my method for understanding tcp handshake.\
You need remember only two things about TCP.

- 1. Every 
- data sent in TCP requires an ack to ensure it has been received. Otherwise, this data will be resent.
- 2. The essence of a TCP connection is the exchange and maintenance of status information,which includes address,port,window size and so on, between the communicating parties

The client sends it's information to the server requires one time of communication
and the server sends it's information to the client requires one time of communication.

```mermaid
{{< mermaid >}}
sequenceDiagram
    participant c 
    participant s
    c->>s: send c's information to s
    s->>c: send s's information to c
{{< /mermaid >}}
```

It requires two rounds of communication ,with each round involving an ip packet containing data and an ack packet. Therefore, it requires a total of 4 ip packets. It's two syns and two acks during the establishment of a TCP connection and two fins and two acks during the closing of a TCP connection. 

```mermaid
{{< mermaid >}}
sequenceDiagram
    participant c 
    participant s
    c->>s: syn
    s->>c: ack
    s->>c: syn
    c->>s: ack
{{< /mermaid >}}
```

```mermaid
{{< mermaid >}}
sequenceDiagram
    participant c 
    participant s
    c->>s: fin
    s->>c: ack
    s->>c: fin
    c->>s: ack
{{< /mermaid >}}
```

We can combine a syn and an ack to one packet during the establishment of a TCP connection to optimize the performance. Therefor, we use a three-way handshake during the establishment of a TCP connection, and a four-way handshake during the closing of a TCP connection.

```mermaid
{{< mermaid >}}
sequenceDiagram
    participant c 
    participant s
    c->>s: syn
    s->>c: syn + ack 
    c->>s: ack
{{< /mermaid >}}
```

```mermaid
{{< mermaid >}}
sequenceDiagram
    participant c 
    participant s
    c->>s: fin
    s->>c: ack
    s->>c: fin
    c->>s: ack
{{< /mermaid >}}
```

# 2. tcp handshake states and linux system calls

We now add the tcp states to the diagrams

## 2.1. establish connection

```mermaid
{{< mermaid >}}
sequenceDiagram
    participant c 
    participant s
    Note right of s: LISTEN
    c->>s: syn
    Note left of c: SYN_SENT
    Note right of s: SYN_RCVD
    s->>c: syn + ack 
    Note left of c: ESTAB
    c->>s: ack
    Note right of s: ESTAB
{{< /mermaid >}}
```

## 2.2. close connection

```mermaid
{{< mermaid >}}
sequenceDiagram
    participant c 
    participant s
    Note over c,s: ESTAB
    c->>s: fin
    Note left of c: FIN_WAIT_1
    Note right of s: CLOSE_WAIT
    s->>c: ack
    Note left of c: FIN_WAIT_2
    s->>c: fin
    Note right of s: LAST_ACK
    Note left of c: TIME_WAIT
    c->>s: ack
    Note right of s: really close here
    c->>c: wait 2 msl
    Note left of c: really close here
{{< /mermaid >}}
```

## 2.3. system calls

To understand how TCP works on linux, we can examine it through the linux system calls. \
The following code is simple examples of tcp client and server on linux.

```c
// client.c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

int main() {
    int client_fd;
    struct sockaddr_in server_address;
    char buffer[1024] = {0};
    char *message = "Hello from client";

    if ((client_fd = socket(AF_INET, SOCK_STREAM, 0)) < 0) {
        perror("socket failed");
        exit(EXIT_FAILURE);
    }

    server_address.sin_family = AF_INET;
    server_address.sin_port = htons(8080);
    if (inet_pton(AF_INET, "127.0.0.1", &server_address.sin_addr) <= 0) {
        perror("inet_pton failed");
        exit(EXIT_FAILURE);
    }

    // send a connect request
    // the tcp's state will change to syn_sent
    if (connect(client_fd, (struct sockaddr *)&server_address, sizeof(server_address)) < 0) {
        perror("connect failed");
        exit(EXIT_FAILURE);
    }

    send(client_fd, message, strlen(message), 0);
    printf("Message sent to server\n");

    int valread = read(client_fd, buffer, 1024);
    printf("%s\n", buffer);

    // close the connection
    // will send fin to server
    // the tcp's state will change from ESTAB to FIN_WAIT_1
    close(client_fd);

    return 0;
}
```

```c
// server.c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <netinet/in.h>

int main() {
    int server_fd, new_socket;
    struct sockaddr_in address;
    int opt = 1;
    int addrlen = sizeof(address);
    char buffer[1024] = {0};
    char *hello = "Hello from server";

    if ((server_fd = socket(AF_INET, SOCK_STREAM, 0)) == 0) {
        perror("socket failed");
        exit(EXIT_FAILURE);
    }

    if (setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR | SO_REUSEPORT, &opt, sizeof(opt))) {
        perror("setsockopt failed");
        exit(EXIT_FAILURE);
    }

    address.sin_family = AF_INET;
    address.sin_addr.s_addr = INADDR_ANY;
    address.sin_port = htons(8080);
    if (bind(server_fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
        perror("bind failed");
        exit(EXIT_FAILURE);
    }

    // listen on a port
    // the tcp's state will change LISTEN
    if (listen(server_fd, 3) < 0) {
        perror("listen failed");
        exit(EXIT_FAILURE);
    }

    while (1) {
        // accept incoming connections
        // this system call just get an established tcp connection from a queue in the kernel
        if ((new_socket = accept(server_fd, (struct sockaddr *)&address, (socklen_t*)&addrlen)) < 0) {
            perror("accept failed");
            exit(EXIT_FAILURE);
        }

        int valread = read(new_socket, buffer, 1024);
        printf("%s\n", buffer);

        send(new_socket, hello, strlen(hello), 0);
        printf("Hello message sent\n");

        // close the tcp connection
        // the behavior of this system call will diverse depends on the current state of the tcp connection
        // if current_state == ESTAB {
        //     current_state = SYN_SENT
        // } else if  current_state == CLOSE_WAIT {
        //     current_state = LAST_ACK
        // }
        close(new_socket);
    }

    return 0;
}
```

### 2.3.1. what does bind do?

The bind system call preserves the port for the server socket to listen on. \
Binding an address without listening on it won't make the server socket available.

### 2.3.2. what does accept do?

The accept system call just get an established tcp connection from a queue in the kernel. \
The kernel processes the three-way handshake and puts the established connections to a queue called accept queue. \
Since the accept system call has no contact with the listen port, we can bind and listen on the parent process and accept on the child process.

### 2.3.3. what does close do?

The close system call on the client side simply sends a fin packet to the server side. \
If the server is in the ESTAB state, the close does the same thing as it does on the client side.

If the client has sent the fin first and the server changes to the CLOSE_WAIT state, things will get more complicated.

There is another question as to why we cannot combine fin and ack to get a three-way handshake during the closing of a TCP connection. \
The answer is that we have exposed a close system call to the application layer, so the kernel cannot close the connection directly. \
The kernel needs to wait for the application to instruct it to close the connection, which's why we call this state CLOSE_WAIT.

# 3. tuntap

You cannot use network interfaces like eth0 to handle network packets because the linux kernel controls them. Instead, you can use virtual network interface to test your custom tcp stack. Tuntap provides you with the ability to fully control the network packets.

Tuntap can create two kinds of virtual network interfaces: tun and tap. Tap is a layer 2 network interface that provides mac frames. Tun is a layer 3 network interface that provides ip packets.


## 3.1. tun

Use this code to start a tun interface and see what it receives

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

Try to send some requests to this tun interface. You may get something like this.

```sh
# send request to the tun
curl -v  http://11.0.0.2/hello
```

get some data

```
00000000  45 00 00 3c 80 40 40 00  40 06 a4 79 0b 00 00 01  |E..<.@@.@..y....|
00000010  0b 00 00 02 bb f8 00 50  08 a8 4a 04 00 00 00 00  |.......P..J.....|
00000020  a0 02 fa f0 67 67 00 00  02 04 05 b4 04 02 08 0a  |....gg..........|
00000030  bf b6 00 fa 00 00 00 00  01 03 03 07              |............|
```


## 3.2. analyze the data

| offset of ip | offset of tcp | byte             | description                                                                 |
| ------------ | ------------- | ---------------- | --------------------------------------------------------------------------- |
| 4/8          |               | 0x4              | ip version ip v4                                                            |
| 1            |               | 0x5              | ip header length is 20 byte:  5 * 4 = 20                                    |
| 2            |               | 0x00             | type of service                                                             |
| 4            |               | 0x003c           | total length 60 byte                                                        |
| 6            |               | 0x8040           | id of the ip                                                                |
| 6 + 3/8      |               | 010              | flags 0:Reserved; must be zero, 1:Don't Fragment (DF) 0:More Fragments (MF) |
| 8            |               | 0 0000 0000 0000 | fragment offset: here is 0                                                  |
| 9            |               | 0x40             | time to live: 64 seconds                                                    |
| 10           |               | 0x06             | protocol: 0x06 means tcp                                                    |
| 12           |               | 0xa479           | header checksum                                                             |
| 16           |               | 0x0b 00 00 01    | source ip:11.0.0.1                                                          |
| 20           |               | 0x0b 00 00 02    | dst ip:11.0.0.2                                                             |
| 22           | 2             | 0xbbf8           | source port: 48120                                                          |
| 24           | 4             | 0x0050           | dst port: 80                                                                |
| 28           | 8             | 0x08a84a04       | sequence number:145246724                                                   |
| 32           | 12            | 0x00000000       | acknowledgement number:0                                                    |
| 33 + 4/8     | 13  + 4/8     | 0xa              | header length: 10 * 4 = 40                                                  |
| 33 + 10/8    | 13  + 10/8    | 0000 00          | reserved                                                                    |
| 34           | 14            | 00 0010          | flags URG:0 ACK:0 PSR:0 RST:0 SYN1:1 FIN:0                                  |
| 36           | 16            | 0xfaf0           | window size:64240                                                           |
| 38           | 18            | 0x6767           | checksum                                                                    |
| 40           | 20            | 0x0000           | urgent pointer                                                              |
| 60           | 40            |                  | tcp options and paddings                                                    |

This is a syn packet of the TCP handshake. These codes do nothing but print out the syn packet content, so the tcp connection won't be established. This is where we begin to write our own tcp/ip stack. 
