
# the default bridge network

tldr

## create a docker container

create a docker compose file to start a redis docker container

```yaml
version: "3"
services:
  redis-lab:
    image: redis:5.0
    container_name: redis-lab
    ports:
      - "16379:6379"
    restart: always
```

<!-- more -->

launch this container with command

```sh
docker compose -f redis-lab-compose.yaml up
```


## your container has been assigned with a ip

you can get your container ip with

```sh
docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' container_name_or_id
```

## a route rule has been created to help your to access your container

you can connect to this redis instance with this ip directly

```sh
redis-cli -h container_ip
```

find out which route rule helps you access this ip

```sh
ip route get container_ip
# output
# 172.18.0.4 dev br-b3da793b3902 src 172.18.0.1 uid 1000
#     cache
```

the string after `br-` is the short network id of the network the container is in \
you can get the network information of it with this command

```sh
docker inspect redis-lab -f "{{json .NetworkSettings.Networks }}"

# output
# {
#   "services_default": {
#     "IPAMConfig": null,
#     "Links": null,
#     "Aliases": [
#       "redis-lab",
#       "redis-lab",
#       "817453f83b5c"
#     ],
#     "NetworkID": "b3da793b390254b4a251ade6d8304a59a0e2036642be1aed6bcf6f2a5d1445d4",
#     "EndpointID": "cb4377ff84ba300fce360275af847d684cf78d4685812535db3c44e695cc7834",
#     "Gateway": "172.18.0.1",
#     "IPAddress": "172.18.0.4",
#     "IPPrefixLen": 16,
#     "IPv6Gateway": "",
#     "GlobalIPv6Address": "",
#     "GlobalIPv6PrefixLen": 0,
#     "MacAddress": "02:42:ac:12:00:04",
#     "DriverOpts": null
#   }
# }
```

## some iptables rules has been created for ports binding

