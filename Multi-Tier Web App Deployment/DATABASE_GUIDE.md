# RDS Database Integration Guide

## What Changed

Your deployment has been updated to:
1. Install PHP on EC2 instances for database connectivity
2. Pass RDS credentials to the web app
3. Display database content in the web application

---

## Step 1: Redeploy with Updated Configuration

After making the changes, redeploy:

```bash
cd /Users/brendonang/Code/AWS\ Project/Multi-Tier\ Web\ App\ Deployment

# Validate changes
terraform plan

# Apply changes
terraform apply
```

The deployment will:
- Create new launch template with PHP installed
- Terminate old EC2 instances
- Launch new instances with database connectivity

---

## Step 2: Connect to RDS and Create Database Schema

### From Your Local Machine - Option A: Via Bastion

1. **SSH into Bastion:**
```bash
ssh -i WebApp-key-pair.pem ec2-user@35.153.140.63
```

2. **Connect to RDS MySQL:**
```bash
mysql -h multitier-webapp-mysql.cy188y02caa5.us-east-1.rds.amazonaws.com \
       -u admin -p
# Enter password: MyPassword123!
```

3. **Select database:**
```sql
USE appdb;
```

4. **Create users table:**
```sql
CREATE TABLE users (
    id INT PRIMARY KEY AUTO_INCREMENT,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(100) NOT NULL UNIQUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

5. **Insert sample data:**
```sql
INSERT INTO users (name, email) VALUES
('John Doe', 'john@example.com'),
('Jane Smith', 'jane@example.com'),
('Bob Johnson', 'bob@example.com'),
('Alice Wilson', 'alice@example.com');
```

6. **Verify data:**
```sql
SELECT * FROM users;
```

### From Your Local Machine - Option B: Using MySQL Client

If you have MySQL installed locally:

```bash
mysql -h multitier-webapp-mysql.cy188y02caa5.us-east-1.rds.amazonaws.com \
       -u admin -p \
       --ssl-mode=REQUIRED \
       -D appdb \
       -e "CREATE TABLE users (
           id INT PRIMARY KEY AUTO_INCREMENT,
           name VARCHAR(100) NOT NULL,
           email VARCHAR(100) NOT NULL UNIQUE,
           created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
       );"

mysql -h multitier-webapp-mysql.cy188y02caa5.us-east-1.rds.amazonaws.com \
       -u admin -p \
       -D appdb \
       -e "INSERT INTO users (name, email) VALUES
           ('John Doe', 'john@example.com'),
           ('Jane Smith', 'jane@example.com'),
           ('Bob Johnson', 'bob@example.com');"
```

---

## Step 3: Access Web Application with Database Content

Once the new instances are running:

1. **Open in browser:**
```
http://multitier-webapp-alb-586845017.us-east-1.elb.amazonaws.com
```

2. **You should see:**
   - Instance metadata (ID, IP, AZ, etc.)
   - "Connected to RDS successfully" message
   - Table displaying all users from the database

---

## Making Database Changes and Seeing Them Reflected

### Add New User to Database:

```bash
# Via Bastion
ssh -i WebApp-key-pair.pem ec2-user@35.153.140.63

mysql -h multitier-webapp-mysql.cy188y02caa5.us-east-1.rds.amazonaws.com \
       -u admin -p \
       -D appdb \
       -e "INSERT INTO users (name, email) VALUES ('New User', 'newuser@example.com');"
```

### Refresh Web Browser:

The new data will appear immediately when you refresh the page.

---

## Modify Web App Queries

To display different data or add new tables:

1. **Edit the PHP section in user_data.sh**
2. **Update the SQL query:**

```php
// Change this line:
$sql = "SELECT id, name, email, created_at FROM users ORDER BY created_at DESC";

// To show only recent users:
$sql = "SELECT id, name, email, created_at FROM users 
        WHERE created_at >= DATE_SUB(NOW(), INTERVAL 7 DAY) 
        ORDER BY created_at DESC";

// Or query a different table:
$sql = "SELECT * FROM products WHERE in_stock = 1";
```

3. **Redeploy:**
```bash
terraform apply
```

---

## Creating Additional Tables

```sql
-- Orders table
CREATE TABLE orders (
    id INT PRIMARY KEY AUTO_INCREMENT,
    user_id INT NOT NULL,
    order_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    total_amount DECIMAL(10, 2),
    FOREIGN KEY (user_id) REFERENCES users(id)
);

-- Products table
CREATE TABLE products (
    id INT PRIMARY KEY AUTO_INCREMENT,
    name VARCHAR(200) NOT NULL,
    price DECIMAL(10, 2),
    in_stock BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

---

## Troubleshooting

### Issue: "Database Connection Failed"

**Cause:** Security group rules blocking connection

**Solution:**
```bash
# Check Web Tier Security Group allows RDS port
aws ec2 describe-security-groups \
    --group-ids sg-0bd01cf8d4a7175dc \
    --region us-east-1
```

Verify port 3306 is allowed from Web Tier SG to RDS SG.

### Issue: "Access denied for user 'admin'"

**Solution:**
1. Verify password in terraform.tfvars matches
2. Check RDS master username (should be `admin`)
3. Ensure no special characters are causing issues

### Issue: No data displaying

1. Check MySQL user table exists:
```sql
SHOW TABLES;
```

2. Check table has data:
```sql
SELECT COUNT(*) FROM users;
```

3. Check PHP errors in EC2 instance:
```bash
ssh -i WebApp-key-pair.pem ec2-user@10.0.207.40
sudo tail -f /var/log/httpd/error_log
```

---

## Advanced: Custom Web App

Replace the PHP code in user_data.sh with your own application:

```php
// Example: Show user count
$result = $conn->query("SELECT COUNT(*) as total FROM users");
$row = $result->fetch_assoc();
echo "Total Users: " . $row['total'];

// Example: Dynamic dashboard
$top_users = $conn->query("SELECT * FROM users LIMIT 5");
```

---

## Security Considerations

⚠️ **Important:** The current setup embeds the database password in the launch template. For production:

1. **Use AWS Secrets Manager:**
```hcl
data "aws_secretsmanager_secret_version" "db_password" {
  secret_id = aws_secretsmanager_secret.db_password.id
}

# Then reference in user_data
```

2. **Use IAM Database Authentication:**
```bash
# Generate temporary token instead of password
aws rds generate-db-auth-token \
    --hostname multitier-webapp-mysql.cy188y02caa5.us-east-1.rds.amazonaws.com \
    --port 3306 \
    --username admin
```

3. **Rotate password regularly:**
```bash
aws rds modify-db-instance \
    --db-instance-identifier multitier-webapp-mysql \
    --master-user-password NewPassword123! \
    --apply-immediately
```

---

## Summary

Your multi-tier architecture now:
- ✅ EC2 instances running PHP
- ✅ Web app connected to RDS MySQL
- ✅ Displays live database content
- ✅ Auto-scales with database support
- ✅ Multi-AZ database replication

Any changes to the database are reflected immediately when you refresh the web page!
