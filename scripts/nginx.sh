#!/bin/bash

#Get IP
local_ipv4="$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)"

#Utils
sudo apt-get install unzip

#Download Consul
CONSUL_VERSION="1.5.3"
CONSUL_TEMPLATE_VERSION="0.22.0"
curl --silent --remote-name https://releases.hashicorp.com/consul/${CONSUL_VERSION}/consul_${CONSUL_VERSION}_linux_amd64.zip
curl --silent --remote-name https://releases.hashicorp.com/consul-template/${CONSUL_TEMPLATE_VERSION}/consul-template_${CONSUL_TEMPLATE_VERSION}_linux_amd64.zip

#Install Consul
unzip consul_${CONSUL_VERSION}_linux_amd64.zip
unzip consul-template_${CONSUL_TEMPLATE_VERSION}_linux_amd64.zip
sudo chown root:root consul consul-template
sudo mv consul* /usr/local/bin/
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

sudo cat << EOF > /etc/systemd/system/consul-template.service
[Unit]
Description="Template rendering, notifier, and supervisor for @hashicorp Consul and Vault data."
Documentation=https://www.consul.io/
Requires=network-online.target
After=network-online.target

[Service]
User=root
Group=root
ExecStart=/usr/local/bin/consul-template -config=/etc/consul-template/consul-template-config.hcl
ExecReload=/usr/local/bin/consul reload
KillMode=process
Restart=always
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

#Create config dirs
sudo mkdir --parents /etc/consul.d
sudo mkdir --parents /etc/nginx/conf.d
sudo mkdir --parents /etc/consul-template

sudo touch /etc/consul.d/consul.hcl
sudo touch /etc/consul-template/consul-template-config.hcl

sudo chown --recursive consul:consul /etc/consul.d
sudo chown --recursive consul:consul /etc/consul-template
sudo chmod 640 /etc/consul.d/consul.hcl
sudo chmod 640 /etc/consul-template/consul-template-config.hcl


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
#     "name": "nginx",
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


# create consul template for nginx config
cat << EOF > /etc/nginx/conf.d/load-balancer.conf.ctmpl
upstream api {
{{ range service "api" }}
  server {{ .Address }}:{{ .Port }};
{{ end }}
}

server {
    listen       80;
    server_name  localhost;

    location / {
        root   /usr/share/nginx/html;
        index  index.html index.htm;
    }
    location /api {
       proxy_pass http://api;
    }
}
EOF

# create consul-template Config
cat << EOF > /etc/consul-template/consul-template-config.hcl
template {
source      = "/etc/nginx/conf.d/load-balancer.conf.ctmpl"
destination = "/etc/nginx/conf.d/default.conf"
command = "docker-compose -f /home/ubuntu/docker-compose.yml restart"
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


#Enable the service
sudo systemctl enable consul
sudo systemctl enable consul-template
sudo service consul start
sudo service consul-template start
sudo service consul status
sudo service consul-template status

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

# install our simple webpage
cat << EOF > /home/ubuntu/index.html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, shrink-to-fit=no">
    <link rel="stylesheet" href="https://maxcdn.bootstrapcdn.com/bootstrap/4.0.0/css/bootstrap.min.css" integrity="sha384-Gn5384xqQ1aoWXA+058RXPxPg6fy4IWvTNh0E263XmFcJlSAwiGgFAW/dAiS6JXm" crossorigin="anonymous">
    <title>Hello, world!</title>
  </head>
  <body>
    <div class="jumbotron">
      <h1 class="display-4">Hello, World!</h1>
      <p class="lead">Zero Touch Application Delivery with F5 BIG-IP, Terraform, and Consul</p>
      <hr class="my-4">
    </div>

    <table style="width:50%">
      <tr>
        <td>Web Server</td>
        <td>$HOSTNAME</td>
      </tr>
      <tr>
        <td>API Server</td>
        <td><div id="servername"></div></td>
      </tr>
      <tr>
        <td>Status Message</td>
        <td><div id="status"></div></td>
      </tr>
    </table>
    <script>
      async function check_api() {
        const response = await fetch('/api/');
        const payload = await response.json();
        document.getElementById("servername").innerText = payload.server
        document.getElementById("status").innerText = payload.status
      }
    setInterval(check_api, 1000)
    </script>
    <script src="https://code.jquery.com/jquery-3.2.1.slim.min.js" integrity="sha384-KJ3o2DKtIkvYIK3UENzmM7KCkRr/rE9/Qpg6aAZGJwFDMVNA/GpGFF93hXpG5KkN" crossorigin="anonymous"></script>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/popper.js/1.12.9/umd/popper.min.js" integrity="sha384-ApNbgh9B+Y1QKtv3Rn7W3mgPxhU9K/ScQsAP7hUibX39j7fakFPskvXusvfa0b4Q" crossorigin="anonymous"></script>
    <script src="https://maxcdn.bootstrapcdn.com/bootstrap/4.0.0/js/bootstrap.min.js" integrity="sha384-JZR6Spejh4U02d8jOt6vLEHfe/JQGiRRSQQxSfFWpi1MquVdAyjUar5+76PVCmYl" crossorigin="anonymous"></script>
  </body>
</html>
<html>

EOF

#Run nginx web instances
cat << EOF > /home/ubuntu/docker-compose.yml
web:
  image: nginx
  ports:
  - "80:80"
  environment:
   - SERVICE_NAME=web
   - SERVICE_80_CHECK_TCP=true
   - SERVICE_80_CHECK_INTERVAL=15s
   - SERVICE_80_CHECK_TIMEOUT=3s

  restart: always
  command: [nginx-debug, '-g', 'daemon off;']
  volumes:
  - /etc/nginx/conf.d/default.conf:/etc/nginx/conf.d/default.conf
  - /home/ubuntu/index.html:/usr/share/nginx/html/index.html

EOF
sudo docker-compose -f /home/ubuntu/docker-compose.yml up -d
sudo touch /etc/resolv.conf
sudo cat << EOF > /etc/resolv.conf
nameserver 127.0.0.1
nameserver 8.8.8.8
EOF
sudo systemctl restart dnsmasq
