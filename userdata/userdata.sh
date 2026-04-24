#!/bin/bash
yum update -y
yum install -y unzip
yum install -y aspnetcore-runtime-9.0
mkdir -p /var/www/yourapp
aws s3 cp s3://your-bucket-name/app.zip /tmp/app.zip
cd /var/www/yourapp
unzip /tmp/app.zip
cat > /etc/systemd/system/yourapp.service << EOF
[Unit]
Description=YourApp AWS
After=network.target

[Service]
WorkingDirectory=/var/www/yourapp
ExecStart=/usr/lib64/dotnet/dotnet /var/www/yourapp/yourapp.dll
Restart=always
Environment=ASPNETCORE_ENVIRONMENT=Production
Environment=ASPNETCORE_URLS=http://0.0.0.0:5000

[Install]
WantedBy=multi-user.target
EOF
systemctl enable yourapp
systemctl start yourapp