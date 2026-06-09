#!/bin/bash
set -e

# Update system packages
yum update -y

# Install required software
yum install -y httpd php php-mysql mysql

# Start and enable Apache web server
systemctl start httpd
systemctl enable httpd

# Create a simple health check page
cat > /var/www/html/health << 'EOF'
OK
EOF

# Create a PHP page that connects to RDS and displays data
cat > /var/www/html/index.php << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Multi-Tier Web App</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; background: #f0f0f0; }
        .container { background: white; padding: 20px; border-radius: 5px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); max-width: 800px; }
        h1 { color: #333; }
        h2 { color: #0066cc; margin-top: 30px; }
        .info { margin: 15px 0; padding: 10px; background: #f9f9f9; border-left: 4px solid #0066cc; }
        .label { font-weight: bold; color: #0066cc; }
        table { width: 100%; border-collapse: collapse; margin: 20px 0; }
        table, th, td { border: 1px solid #ddd; padding: 12px; text-align: left; }
        th { background-color: #0066cc; color: white; }
        .error { color: #cc0000; padding: 10px; background: #ffe6e6; border-left: 4px solid #cc0000; }
        .success { color: #00cc00; padding: 10px; background: #e6ffe6; border-left: 4px solid #00cc00; }
    </style>
</head>
<body>
    <div class="container">
        <h1>✓ Multi-Tier Web Application Deployed</h1>
        <p>This instance is successfully running and connected to RDS.</p>

        <div class="info">
            <div class="label">Instance ID:</div>
            <div><?php echo gethostname() . " (instance metadata)"; ?></div>
        </div>

        <div class="info">
            <div class="label">Server IP:</div>
            <div><?php echo $_SERVER['SERVER_ADDR']; ?></div>
        </div>

        <h2>Database Users</h2>

        <?php
            // RDS Connection Details - Update these with your credentials
            $db_host = '${rds_endpoint}';
            $db_user = 'admin';
            $db_password = '${rds_password}';
            $db_name = 'appdb';

            // Create connection
            $conn = new mysqli($db_host, $db_user, $db_password, $db_name);

            // Check connection
            if ($conn->connect_error) {
                echo '<div class="error"><strong>Database Connection Failed:</strong> ' . $conn->connect_error . '</div>';
                echo '<p>Make sure RDS password is set correctly in index.php</p>';
            } else {
                echo '<div class="success">✓ Connected to RDS successfully</div>';

                // Query users table
                $sql = "SELECT id, name, email, created_at FROM users ORDER BY created_at DESC";
                $result = $conn->query($sql);

                if ($result && $result->num_rows > 0) {
                    echo '<table>';
                    echo '<tr><th>ID</th><th>Name</th><th>Email</th><th>Created At</th></tr>';
                    while($row = $result->fetch_assoc()) {
                        echo '<tr>';
                        echo '<td>' . htmlspecialchars($row["id"]) . '</td>';
                        echo '<td>' . htmlspecialchars($row["name"]) . '</td>';
                        echo '<td>' . htmlspecialchars($row["email"]) . '</td>';
                        echo '<td>' . htmlspecialchars($row["created_at"]) . '</td>';
                        echo '</tr>';
                    }
                    echo '</table>';
                } else {
                    echo '<p>No users found in database. Create some with: INSERT INTO users (name, email) VALUES (...)</p>';
                }

                $conn->close();
            }
        ?>

        <h2>Database Endpoint Info</h2>
        <div class="info">
            <div class="label">RDS Endpoint:</div>
            <div>${rds_endpoint}</div>
        </div>
        <div class="info">
            <div class="label">Database Name:</div>
            <div>appdb</div>
        </div>
    </div>
</body>
</html>
EOF

# Set proper permissions
chmod 644 /var/www/html/index.php
chmod 644 /var/www/html/health
