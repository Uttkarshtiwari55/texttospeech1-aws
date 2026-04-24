# Deployment Guide — Highly Available Text-to-Speech App on AWS

## Overview
This guide walks through deploying a .NET 9 ASP.NET Core application on AWS with a highly available, auto-scaling architecture. The app uses AWS Polly for text-to-speech conversion and AWS Comprehend for language detection, deployed across multiple Availability Zones behind an Application Load Balancer.

## Architecture

```
Internet
    ↓
Application Load Balancer (public subnets — AZ-a, AZ-b)
    ↓
Auto Scaling Group
    ├── EC2 Instance (AZ-a)
    └── EC2 Instance (AZ-b)
            ↓
    IAM Role (least-privilege)
    ├── AWS Polly
    ├── AWS Comprehend
    └── S3 (app artifact)
```

## AWS Services Used
- **VPC** — Custom network with public subnets across 2 Availability Zones
- **EC2** — Application servers running the .NET 9 app
- **Application Load Balancer** — Distributes incoming traffic across instances
- **Auto Scaling Group** — Maintains desired capacity, replaces unhealthy instances
- **S3** — Stores the application zip for deployment
- **IAM** — Role-based access to AWS services, no hardcoded credentials
- **AWS Polly** — Text-to-speech synthesis
- **AWS Comprehend** — Language detection and NLP

## Prerequisites
- AWS account with free tier
- .NET 9 ASP.NET Core app published and zipped
- AWS Console access via IAM user (never use root account)

## Step 1 — Upload App to S3

1. Go to **S3 console** → Create bucket
   - Name: `your-bucket-name` (lowercase, no spaces)
   - Region: `ap-south-1` (Mumbai) or your preferred region
   - Block all public access: ON
2. Upload your `app.zip` to the bucket
   - Zip contents should be at root level — `youapp.dll`, `wwwroot/` etc directly inside, not nested in a subfolder

## Step 2 — Create VPC

1. Go to **VPC console** → Create VPC → select **VPC and more**
2. Settings:
   - Name: `yourapp-vpc`
   - IPv4 CIDR: `10.0.0.0/16`
   - Availability Zones: 2
   - Public subnets: 2
   - Private subnets: 2
   - NAT Gateways: None
3. After creation, enable auto-assign public IPv4 on both public subnets:
   - VPC → Subnets → select each public subnet → Actions → Edit subnet settings → Enable auto-assign public IPv4

> **Note:** Auto-assign public IP must be enabled on public subnets, otherwise instances won't have internet access even in public subnets.

## Step 3 — Create IAM Role

1. IAM console → Roles → Create role
2. Trusted entity: **EC2**
3. Attach these policies:
   - `AmazonPollyFullAccess`
   - `ComprehendFullAccess`
   - `AmazonS3ReadOnlyAccess`
4. Name: `EC2-YourApp-Role`

## Step 4 — Create Security Groups

### ALB Security Group
- Name: `alb-sg`
- VPC: your VPC
- Inbound: HTTP port 80 from `0.0.0.0/0`
- Outbound: All traffic

### EC2 Security Group
- Name: `ec2-sg`
- VPC: your VPC
- Inbound:
  - Custom TCP port `5000` from `alb-sg` (only ALB can reach app)
  - SSH port `22` from your IP only
  - SSH port `22` from `13.233.177.0/29` (AWS EC2 Instance Connect for ap-south-1)
- Outbound: All traffic

## Step 5 — Create Launch Template

1. EC2 → Launch Templates → Create launch template
2. Settings:
   - AMI: Amazon Linux 2023 kernel-6.18 (64-bit x86, free tier)
   - Instance type: `t3.micro` (free tier eligible in ap-south-1)
   - Key pair: Create new, download and save the `.pem` file
   - Security group: `ec2-sg`
   - IAM instance profile: your IAM role
3. Advanced details → User data:

```bash
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
```

> **Important:** Replace `your-bucket-name` and `yourapp` with your actual values before using.

> **Key learnings from deployment:**
> - Use `aspnetcore-runtime-9.0` not `dotnet-runtime-9.0` — ASP.NET Core apps need the ASP.NET Core runtime, not just the base .NET runtime
> - Dotnet binary is at `/usr/lib64/dotnet/dotnet` on Amazon Linux 2023, not `/usr/bin/dotnet`

## Step 6 — Create Target Group

1. EC2 → Target Groups → Create target group
2. Settings:
   - Target type: Instances
   - Name: `yourapp-tg`
   - Protocol: HTTP
   - Port: `5000` (must match your app's listening port)
   - VPC: your VPC
   - Health check path: `/`
   - Healthy threshold: 2
   - Unhealthy threshold: 3
   - Interval: 30 seconds
3. Do not register any targets manually — ASG handles this automatically

## Step 7 — Create Application Load Balancer

1. EC2 → Load Balancers → Create → Application Load Balancer
2. Settings:
   - Name: `yourapp-alb`
   - Scheme: Internet-facing
   - VPC: your VPC
   - Subnets: select both **public** subnets
   - Security group: `alb-sg`
   - Listener: HTTP port 80 → Forward to your target group
3. Wait for state to change from Provisioning to **Active**

## Step 8 — Create Auto Scaling Group

1. EC2 → Auto Scaling Groups → Create
2. Settings:
   - Name: `yourapp-asg`
   - Launch template: your launch template
   - VPC: your VPC
   - Subnets: both **public** subnets
   - Load balancing: attach to your target group
   - ELB health checks: enabled
   - Health check grace period: 300 seconds
   - Desired capacity: 2
   - Minimum: 1
   - Maximum: 3
   - Scaling policy: Target tracking, CPU utilization at 50%
3. Add tag: Key `Name`, Value `yourapp-ec2`

## Step 9 — Test

1. Copy ALB DNS name from Load Balancers console
2. Open browser and navigate to `http://your-alb-dns-name` (use http not https)
3. Your app should load within 5-6 minutes of ASG launching instances

To verify app is running on an instance:
```bash
# SSH in via EC2 Instance Connect
systemctl status yourapp
curl http://localhost:5000
```

## Teardown (to avoid charges)

Delete resources in this order:

1. Auto Scaling Group — set desired/min to 0 first, then delete
2. Application Load Balancer
3. Target Groups
4. Launch Template
5. EC2 Key Pair
6. Security Groups (ec2-sg first, then alb-sg)
7. VPC (this deletes subnets, route tables, IGW automatically)
8. S3 — empty bucket first, then delete
9. IAM Role
10. CloudWatch billing alarms (optional)

## Troubleshooting

| Problem | Cause | Fix |
|---|---|---|
| User Data script fails with timeout | Private subnets have no internet | Use public subnets with auto-assign public IP enabled |
| S3 download 404 error | Wrong bucket name or file name in User Data | Verify exact bucket name and file name match |
| App fails with exit-code 150 | Wrong .NET runtime package installed | Use `aspnetcore-runtime-9.0` not `dotnet-runtime-9.0` |
| Browser timeout on ALB URL | Browser forcing HTTPS | Explicitly use `http://` in URL |
| Instances unhealthy in TG | App not running on port 5000 | Check systemctl status and journalctl logs |
| EC2 Instance Connect fails | No public IP on instance | Enable auto-assign public IPv4 on subnet |

## Key Concepts Demonstrated

**High Availability** — Instances deployed across 2 AZs. If one AZ goes down the other continues serving traffic.

**Self-healing** — ASG monitors ELB health checks. Unhealthy instances are automatically terminated and replaced with fresh ones.

**Least-privilege IAM** — EC2 instances use an IAM role instead of hardcoded credentials. Role only has access to Polly, Comprehend and S3 — nothing else.

**Infrastructure as Code (next step)** — This entire setup can be replicated in minutes using CloudFormation or Terraform instead of manual console clicks.

**Elastic scaling** — Target tracking policy automatically adds instances when CPU exceeds 50% and removes them when load drops, optimizing cost.
