#!/bin/bash

#Get IP
local_ipv4="$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)"

#Utils
sudo apt-get install unzip

#Download Consul
CONSUL_VERSION="1.5.3"
curl --silent --remote-name https://releases.hashicorp.com/consul/${CONSUL_VERSION}/consul_${CONSUL_VERSION}_linux_amd64.zip

#Install Consul
unzip consul_${CONSUL_VERSION}_linux_amd64.zip
sudo chown root:root consul
sudo mv consul /usr/local/bin/
consul -autocomplete-install
complete -C /usr/local/bin/consul consul

#Create Consul User
sudo useradd --system --home /etc/consul.d --shell /bin/false consul
sudo mkdir --parents /opt/consul
sudo chown --recursive consul:consul /opt/consul

#Create Systemd Config
sudo cat << EOF > /etc/systemd/system/consul.service
[Unit]
Description="HashiCorp Consul - A service mesh solution"
Documentation=https://www.consul.io/
Requires=network-online.target
After=network-online.target
ConditionFileNotEmpty=/etc/consul.d/consul.hcl

[Service]
User=consul
Group=consul
ExecStart=/usr/local/bin/consul agent -config-dir=/etc/consul.d/
ExecReload=/usr/local/bin/consul reload
KillMode=process
Restart=always
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

#Create config dir
sudo mkdir --parents /etc/consul.d
sudo touch /etc/consul.d/consul.hcl
sudo chown --recursive consul:consul /etc/consul.d
sudo chmod 640 /etc/consul.d/consul.hcl

cat << EOF > /etc/consul.d/consul.hcl
datacenter = "dc1"
data_dir = "/opt/consul"
ui = true
EOF

cat << EOF > /etc/consul.d/client.hcl
advertise_addr = "${local_ipv4}"
retry_join = ["provider=aws tag_key=Env tag_value=consul"]
EOF

# cat << EOF > /etc/consul.d/nginx.json
# {
#   "service": {
#     "name": "api",
#     "port": 80,
#     "checks": [
#       {
#         "id": "nginx",
#         "name": "nginx TCP Check",
#         "tcp": "localhost:80",
#         "interval": "10s",
#         "timeout": "1s"
#       }
#     ]
#   }
# }
# EOF

# create default nginx config

sudo mkdir --parents /etc/nginx/conf.d
cat << EOF > /etc/nginx/conf.d/default.conf

server {
    listen       80;
    server_name  localhost;
    location /api/ {
	     return 200 '{"server":"\$hostname", "status": "online"}';
    }
}
EOF

# create dnsmasq config
touch /etc/dnsmasq.d/dnsmasq.conf
cat << EOF > /etc/dnsmasq.d/dnsmasq.conf
port=53
domain-needed
bogus-priv
strict-order
expand-hosts
listen-address=127.0.0.1
server=/consul/127.0.0.1#8600
server=8.8.8.8
EOF

echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf

# disable resolved / use dnsmasq
sudo systemctl disable systemd-resolved
sudo systemctl stop systemd-resolved
DEBIAN_FRONTEND=noninteractive sudo apt-get update
DEBIAN_FRONTEND=noninteractive sudo apt-get --yes install dnsmasq
echo "127.0.0.1 $(hostname)" | sudo tee -a /etc/hosts

#Enable/restart services
sudo systemctl enable consul
sudo service consul start
sudo service consul status

#Install Docker
sudo snap install docker
sudo curl -L "https://github.com/docker/compose/releases/download/1.24.1/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
sleep 10
sudo usermod -aG docker ubuntu

# Run Registrator
sudo docker run -d \
  --name=registrator \
  --net=host \
  --volume=/var/run/docker.sock:/tmp/docker.sock \
  gliderlabs/registrator:latest \
  consul://localhost:8500


#Run nginx api instances
cat << EOF > /home/ubuntu/docker-compose.yml
api:
  image: nginx
  ports:
  - "80"
  environment:
   - SERVICE_NAME=api
   - SERVICE_80_CHECK_TCP=true
   - SERVICE_80_CHECK_INTERVAL=15s
   - SERVICE_80_CHECK_TIMEOUT=3s

  restart: always
  command: [nginx-debug, '-g', 'daemon off;']
  volumes:
  - /etc/nginx/conf.d/default.conf:/etc/nginx/conf.d/default.conf

EOF
sudo docker-compose -f /home/ubuntu/docker-compose.yml up -d

sudo touch /etc/resolv.conf
sudo cat << EOF > /etc/resolv.conf
nameserver 127.0.0.1
nameserver 8.8.8.8
EOF
sudo systemctl restart dnsmasq
