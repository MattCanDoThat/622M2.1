#!/bin/bash
set -euo pipefail

# ----------------------------
# On my honor, as an Aggie, I have neither given nor received unauthorized assistance on this assignment.
# I further affirm that I have not and will not provide this code to any person, platform, or repository,
# without the express written permission of Dr. Gomillion.
# I understand that any violation of these standards will have serious repercussions.
# ----------------------------

# ----------------------------
# Capture log output so you can troubleshoot if/when needed
# ----------------------------
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

touch /root/1-script-started

# ----------------------------
# Progress Logging (clean STEP banners + status lines only)
# ----------------------------
ProgressLog="/var/log/user-data-progress.log"
touch "$ProgressLog"
chmod 644 "$ProgressLog"

TotalSteps=10
CurrentStep=0

NextStep() {
  CurrentStep=$((CurrentStep+1))
  Percent=$((CurrentStep*100/TotalSteps))

  {
    echo ""
    echo "=================================================="
    echo "STEP $CurrentStep of $TotalSteps  [$Percent%]"
    echo "$1"
    echo "=================================================="
  } | tee -a "$ProgressLog"
}

LogStatus() {
  echo "Status: $1" | tee -a "$ProgressLog"
}

# ----------------------------
# SSH Watcher: smooth ASCII bar + STEP X/10 + label + spinner (no blinking)
# Usage after SSH: watchud
# Auto-exits at STEP 10 with 10s countdown
# ----------------------------

cat > /usr/local/bin/watch-userdata-progress <<'EOF'
#!/bin/bash
set -u

ProgressLog="/var/log/user-data-progress.log"
TotalBarWidth=24
RefreshSeconds=0.5

if [ ! -f "$ProgressLog" ]; then
  echo "Progress log not found: $ProgressLog"
  exit 1
fi

# Colors only when output is a real terminal
if [ -t 1 ]; then
  C_RESET=$'\033[0m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
  C_CYAN=$'\033[36m'
  C_YELLOW=$'\033[33m'
  C_GREEN=$'\033[32m'
else
  C_RESET=""
  C_DIM=""
  C_BOLD=""
  C_CYAN=""
  C_YELLOW=""
  C_GREEN=""
fi

Cols=$(tput cols 2>/dev/null || echo 120)

DrawBar() {
  local Percent="$1"
  local Filled=$((Percent * TotalBarWidth / 100))
  local Empty=$((TotalBarWidth - Filled))

  printf "["
  if [ "$Filled" -gt 0 ]; then
    printf "%s" "${C_CYAN}"
    printf "%0.s#" $(seq 1 "$Filled")
    printf "%s" "${C_RESET}"
  fi
  if [ "$Empty" -gt 0 ]; then
    printf "%s" "${C_DIM}"
    printf "%0.s-" $(seq 1 "$Empty")
    printf "%s" "${C_RESET}"
  fi
  printf "] %s%%" "$Percent"
}

GetLatestStepLine() {
  grep -E "STEP [0-9]+ of [0-9]+  \[[0-9]+%\]" "$ProgressLog" 2>/dev/null | tail -n 1 || true
}

GetLatestPercent() {
  local line
  line="$(GetLatestStepLine)"
  if [ -n "$line" ]; then
    echo "$line" | sed -n 's/.*\[\([0-9]\+\)%\].*/\1/p'
  else
    echo "0"
  fi
}

GetLatestStepNumbers() {
  local line
  line="$(GetLatestStepLine)"
  if [ -n "$line" ]; then
    echo "$line" | sed -n 's/STEP \([0-9]\+\) of \([0-9]\+\).*/\1 \2/p'
  else
    echo "0 0"
  fi
}

GetLatestLabel() {
  awk '/STEP [0-9]+ of [0-9]+  \[[0-9]+%\]/{getline; print}' "$ProgressLog" 2>/dev/null | tail -n 1 || true
}

RenderLine() {
  local Percent="$1"
  local StepNow="$2"
  local StepTotal="$3"
  local Label="$4"
  local Frame="$5"

  local Bar StepText Text
  Bar="$(DrawBar "$Percent")"

  if [ "${StepTotal:-0}" -gt 0 ]; then
    StepText="${C_GREEN}STEP ${StepNow}/${StepTotal}${C_RESET}"
  else
    StepText=""
  fi

  Text="${C_BOLD}Deploying${C_RESET} ${Bar}  ${StepText}  ${C_YELLOW}${Label}${C_RESET}  ${Frame}"

  # Print one line, padded to terminal width to overwrite previous content (no flicker)
  printf "\r%-*s" "$Cols" "$Text"
}

echo ""
echo "${C_BOLD}Watching EC2 user-data progress${C_RESET} (Ctrl+C to stop)"
echo ""

# Show some context
tail -n 20 "$ProgressLog" 2>/dev/null || true

LastLineCount=$(wc -l < "$ProgressLog" 2>/dev/null || echo 0)

TargetPercent="$(GetLatestPercent)"
ShownPercent="$TargetPercent"
read -r StepNow StepTotal <<<"$(GetLatestStepNumbers)"
CurrentLabel="$(GetLatestLabel)"
[ -z "${CurrentLabel:-}" ] && CurrentLabel="Starting..."

i=0
frames='|/-\'

while true; do
  CurrentLineCount=$(wc -l < "$ProgressLog" 2>/dev/null || echo "$LastLineCount")

  # Print any newly appended lines
  if [ "$CurrentLineCount" -gt "$LastLineCount" ]; then
    # Move off the dashboard line cleanly
    printf "\r%-*s\n" "$Cols" " "
    sed -n "$((LastLineCount+1)),$CurrentLineCount"p "$ProgressLog" 2>/dev/null || true
    LastLineCount="$CurrentLineCount"
  fi

  # Update targets from log
  NewTarget="$(GetLatestPercent)"
  [ -n "${NewTarget:-}" ] && TargetPercent="$NewTarget"

  read -r NewStepNow NewStepTotal <<<"$(GetLatestStepNumbers)"
  [ -n "${NewStepNow:-}" ] && StepNow="$NewStepNow"
  [ -n "${NewStepTotal:-}" ] && StepTotal="$NewStepTotal"

  NewLabel="$(GetLatestLabel)"
  [ -n "${NewLabel:-}" ] && CurrentLabel="$NewLabel"

  # Smooth-fill toward the target
  if [ "$ShownPercent" -lt "$TargetPercent" ]; then
    ShownPercent=$((ShownPercent+1))
  elif [ "$ShownPercent" -gt "$TargetPercent" ]; then
    ShownPercent="$TargetPercent"
  fi

  # Completion check
  if tail -n 50 "$ProgressLog" 2>/dev/null | grep -q "STEP 10 of 10"; then
    RenderLine 100 10 10 "$CurrentLabel" ""
    printf "\n\n${C_GREEN}Reached STEP 10 of 10.${C_RESET}\nClosing in 10 seconds...\n"
    sleep 10
    echo "Done."
    exit 0
  fi

  frame="${frames:i%4:1}"
  RenderLine "$ShownPercent" "$StepNow" "$StepTotal" "$CurrentLabel" "$frame"

  i=$((i+1))
  sleep "$RefreshSeconds"
done
EOF

chmod 755 /usr/local/bin/watch-userdata-progress

# ----------------------------
# Create a real command (not an alias) so it works immediately on every instance
# ----------------------------

cat > /usr/local/bin/watchud <<'EOF'
#!/bin/bash
exec /usr/local/bin/watch-userdata-progress
EOF
chmod 755 /usr/local/bin/watchud

# ----------------------------
# Optional: also add alias for convenience (harmless if bashrc is not loaded)
# ----------------------------

if [ -f /home/ubuntu/.bashrc ] && ! grep -q "alias watchud=" /home/ubuntu/.bashrc 2>/dev/null; then
  echo "" >> /home/ubuntu/.bashrc
  echo "alias watchud='/usr/local/bin/watchud'" >> /home/ubuntu/.bashrc
fi
chown ubuntu:ubuntu /home/ubuntu/.bashrc 2>/dev/null || true

# ----------------------------
# System prep
# ----------------------------

NextStep "System preparation and package updates"
LogStatus "Updating packages (apt update/upgrade)"
apt update
apt upgrade -y
touch /root/2-packages-upgraded

LogStatus "Installing prerequisites (curl, unzip, wget)"
apt install apt-transport-https curl unzip wget -y
LogStatus "Prerequisites installed"

# ----------------------------
# MariaDB install
# ----------------------------

NextStep "Installing and starting MariaDB"
LogStatus "Adding MariaDB repo key and sources"
mkdir -p /etc/apt/keyrings
curl -o /etc/apt/keyrings/mariadb-keyring.pgp 'https://mariadb.org/mariadb_release_signing_key.pgp'

cat > /etc/apt/sources.list.d/mariadb.sources <<'EOF'
X-Repolib-Name: MariaDB
Types: deb
URIs: https://mirrors.accretive-networks.net/mariadb/repo/11.8/ubuntu
Suites: noble
Components: main main/debug
Signed-By: /etc/apt/keyrings/mariadb-keyring.pgp
EOF

LogStatus "Installing MariaDB server"
apt update
apt install mariadb-server -y

LogStatus "Enabling and starting MariaDB service"
systemctl enable mariadb
systemctl start mariadb

touch /root/3-mariadb-installed

# ----------------------------
# Verify MariaDB is running
# ----------------------------

systemctl is-active --quiet mariadb
if [ $? -ne 0 ]; then
  echo "ERROR: MariaDB did not start"
  exit 1
fi
echo "MariaDB is running"
LogStatus "MariaDB is running"

# ----------------------------
# Create unprivileged Linux user: mbennett
# ----------------------------

NextStep "Creating unprivileged Linux user"
LogStatus "Creating Linux user (mbennett)"
if id "mbennett" &>/dev/null; then
  echo "Linux user mbennett already exists"
else
  useradd -m -s /bin/bash "mbennett"
  echo "Created Linux user mbennett"
fi
LogStatus "Linux user step completed"

# ----------------------------
# Download + unzip data AS mbennett
# ----------------------------

NextStep "Downloading and unzipping source data"
LogStatus "Downloading dataset zip"
sudo -u "mbennett" wget -O "/home/mbennett/313007119.zip" "https://622.gomillion.org/data/313007119.zip"

# ----------------------------
# Verify the zip exists and is non-empty
# ----------------------------

if [ ! -s "/home/mbennett/313007119.zip" ]; then
  echo "ERROR: Download failed or zip is empty: /home/mbennett/313007119.zip"
  ls -l "/home/mbennett"
  exit 1
fi

LogStatus "Unzipping dataset"
sudo -u "mbennett" unzip -o "/home/mbennett/313007119.zip" -d "/home/mbennett"

echo "Listing /home/mbennett after unzip:"
sudo -u "mbennett" ls -l "/home/mbennett"

# ----------------------------
# Verify expected CSVs exist
# ----------------------------

if [ ! -f "/home/mbennett/customers.csv" ] || \
   [ ! -f "/home/mbennett/orders.csv" ] || \
   [ ! -f "/home/mbennett/orderlines.csv" ] || \
   [ ! -f "/home/mbennett/products.csv" ]; then
  echo "ERROR: One or more CSV files are missing after unzip."
  sudo -u "mbennett" ls -l "/home/mbennett"
  exit 1
fi
LogStatus "Dataset downloaded and verified"

# ----------------------------
# Create MariaDB user and pass: mbennett
# ----------------------------

NextStep "Creating MariaDB user and granting POS privileges"
DbPass="MyVoiceIsMyPassport!"
LogStatus "Creating DB user and granting privileges"

mariadb -e "CREATE USER IF NOT EXISTS 'mbennett'@'localhost' IDENTIFIED BY '${DbPass}';"
mariadb -e "GRANT ALL PRIVILEGES ON POS.* TO 'mbennett'@'localhost';"
mariadb -e "FLUSH PRIVILEGES;"

LogStatus "DB user created and privileges granted"

# ----------------------------
# Generate etl.sql in /home/mbennett
# ----------------------------

NextStep "Generating etl.sql"
LogStatus "Writing etl.sql to disk"

cat > "/home/mbennett/etl.sql" <<'EOF'
DROP DATABASE IF EXISTS POS;
CREATE DATABASE POS;
USE POS;

CREATE TABLE City
(
  zip   DECIMAL(5) ZEROFILL NOT NULL,
  city  VARCHAR(32)         NOT NULL,
  state VARCHAR(4)          NOT NULL,
  PRIMARY KEY (zip)
) ENGINE=InnoDB;

CREATE TABLE Customer
(
  id        SERIAL       NOT NULL,
  firstName VARCHAR(32)  NOT NULL,
  lastName  VARCHAR(30)  NOT NULL,
  email     VARCHAR(128) NULL,
  address1  VARCHAR(100) NULL,
  address2  VARCHAR(50)  NULL,
  phone     VARCHAR(32)  NULL,
  birthdate DATE         NULL,
  zip       DECIMAL(5) ZEROFILL NOT NULL,
  PRIMARY KEY (id),
  CONSTRAINT fk_customer_city
    FOREIGN KEY (zip) REFERENCES City(zip)
) ENGINE=InnoDB;

CREATE TABLE Product
(
  id                SERIAL         NOT NULL,
  name              VARCHAR(128)   NOT NULL,
  currentPrice      DECIMAL(6,2)   NOT NULL,
  availableQuantity INT            NOT NULL,
  PRIMARY KEY (id)
) ENGINE=InnoDB;

CREATE TABLE `Order`
(
  id          SERIAL       NOT NULL,
  datePlaced  DATE         NULL,
  dateShipped DATE         NULL,
  customer_id BIGINT UNSIGNED NOT NULL,
  PRIMARY KEY (id),
  CONSTRAINT fk_order_customer
    FOREIGN KEY (customer_id) REFERENCES Customer(id)
) ENGINE=InnoDB;

CREATE TABLE Orderline
(
  order_id   BIGINT UNSIGNED NOT NULL,
  product_id BIGINT UNSIGNED NOT NULL,
  quantity   INT             NOT NULL,
  PRIMARY KEY (order_id, product_id),
  CONSTRAINT fk_orderline_order
    FOREIGN KEY (order_id) REFERENCES `Order`(id),
  CONSTRAINT fk_orderline_product
    FOREIGN KEY (product_id) REFERENCES Product(id)
) ENGINE=InnoDB;

CREATE TABLE PriceHistory
(
  id         SERIAL       NOT NULL,
  oldPrice   DECIMAL(6,2) NULL,
  newPrice   DECIMAL(6,2) NOT NULL,
  ts         TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  product_id BIGINT UNSIGNED NOT NULL,
  PRIMARY KEY (id),
  CONSTRAINT fk_pricehistory_product
    FOREIGN KEY (product_id) REFERENCES Product(id)
) ENGINE=InnoDB;

CREATE TABLE staging_customer
(
  ID VARCHAR(50),
  FN VARCHAR(255),
  LN VARCHAR(255),
  CT VARCHAR(255),
  ST VARCHAR(255),
  ZP VARCHAR(50),
  S1 VARCHAR(255),
  S2 VARCHAR(255),
  EM VARCHAR(255),
  BD VARCHAR(50)
) ENGINE=InnoDB;

CREATE TABLE staging_orders
(
  OID     VARCHAR(50),
  CID     VARCHAR(50),
  Ordered VARCHAR(50),
  Shipped VARCHAR(50)
) ENGINE=InnoDB;

CREATE TABLE staging_orderlines
(
  OID VARCHAR(50),
  PID VARCHAR(50)
) ENGINE=InnoDB;

CREATE TABLE staging_products
(
  ID               VARCHAR(50),
  Name             VARCHAR(255),
  Price            VARCHAR(50),
  Quantity_on_Hand VARCHAR(50)
) ENGINE=InnoDB;

LOAD DATA LOCAL INFILE '/home/mbennett/customers.csv'
INTO TABLE staging_customer
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES;

LOAD DATA LOCAL INFILE '/home/mbennett/orders.csv'
INTO TABLE staging_orders
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES;

LOAD DATA LOCAL INFILE '/home/mbennett/orderlines.csv'
INTO TABLE staging_orderlines
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES;

LOAD DATA LOCAL INFILE '/home/mbennett/products.csv'
INTO TABLE staging_products
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(@ID, @Name, @Price, @QOH)
SET
  ID = @ID,
  Name = @Name,
  Price = @Price,
  Quantity_on_Hand = @QOH;

INSERT INTO City (zip, city, state)
SELECT DISTINCT
  CAST(LPAD(NULLIF(ZP,''), 5, '0') AS UNSIGNED) AS zip,
  CT AS city,
  ST AS state
FROM staging_customer
WHERE NULLIF(ZP,'') IS NOT NULL;

INSERT INTO Customer (id, firstName, lastName, email, address1, address2, phone, birthdate, zip)
SELECT
  CAST(ID AS UNSIGNED) AS id,
  FN AS firstName,
  LN AS lastName,
  NULLIF(EM,'') AS email,
  NULLIF(S1,'') AS address1,
  NULLIF(S2,'') AS address2,
  NULL AS phone,
  STR_TO_DATE(NULLIF(BD,''), '%m/%d/%Y') AS birthdate,
  CAST(LPAD(NULLIF(ZP,''), 5, '0') AS UNSIGNED) AS zip
FROM staging_customer;

INSERT INTO Product (id, name, currentPrice, availableQuantity)
SELECT
  CAST(ID AS UNSIGNED) AS id,
  Name AS name,
  CAST(
    REPLACE(
      REPLACE(NULLIF(Price,''), '$', ''),
    ',', '')
  AS DECIMAL(6,2)) AS currentPrice,
  CAST(NULLIF(Quantity_on_Hand,'') AS UNSIGNED) AS availableQuantity
FROM staging_products;

INSERT INTO `Order` (id, datePlaced, dateShipped, customer_id)
SELECT
  CAST(OID AS UNSIGNED) AS id,
  CASE
    WHEN NULLIF(Ordered,'') IS NULL THEN NULL
    WHEN LOWER(Ordered) = 'cancelled' THEN NULL
    ELSE DATE(STR_TO_DATE(Ordered, '%Y-%m-%d %H:%i:%s'))
  END AS datePlaced,
  CASE
    WHEN NULLIF(Shipped,'') IS NULL THEN NULL
    WHEN LOWER(Shipped) = 'cancelled' THEN NULL
    ELSE DATE(STR_TO_DATE(Shipped, '%Y-%m-%d %H:%i:%s'))
  END AS dateShipped,
  CAST(CID AS UNSIGNED) AS customer_id
FROM staging_orders;

INSERT INTO Orderline (order_id, product_id, quantity)
SELECT
  CAST(OID AS UNSIGNED) AS order_id,
  CAST(PID AS UNSIGNED) AS product_id,
  COUNT(*) AS quantity
FROM staging_orderlines
GROUP BY
  CAST(OID AS UNSIGNED),
  CAST(PID AS UNSIGNED);

INSERT INTO PriceHistory (oldPrice, newPrice, product_id)
SELECT
  NULL AS oldPrice,
  currentPrice AS newPrice,
  id AS product_id
FROM Product;

DROP TABLE staging_customer;
DROP TABLE staging_orders;
DROP TABLE staging_orderlines;
DROP TABLE staging_products;
EOF

chown "mbennett:mbennett" "/home/mbennett/etl.sql"
LogStatus "etl.sql generated"

# ----------------------------
# Generate views.sql in /home/mbennett
# ----------------------------

NextStep "Generating views.sql (view, materialized view, triggers)"
LogStatus "Writing views.sql to disk"

cat > "/home/mbennett/views.sql" <<'EOF'
USE POS;

DROP VIEW IF EXISTS v_ProductBuyers;

CREATE VIEW v_ProductBuyers AS
SELECT
    p.id AS productID,
    p.name AS productName,
    IFNULL(
        GROUP_CONCAT(
            DISTINCT CONCAT(c.id, ' ', c.firstName, ' ', c.lastName)
            ORDER BY c.id
            SEPARATOR ', '
        ),
        ''
    ) AS customers
FROM Product p
LEFT JOIN Orderline ol ON p.id = ol.product_id
LEFT JOIN `Order` o ON ol.order_id = o.id
LEFT JOIN Customer c ON o.customer_id = c.id
GROUP BY p.id, p.name
ORDER BY p.id;

DROP TABLE IF EXISTS mv_ProductBuyers;

CREATE TABLE mv_ProductBuyers AS
SELECT * FROM v_ProductBuyers;

CREATE INDEX idx_mv_productID
ON mv_ProductBuyers(productID);

DROP TRIGGER IF EXISTS trg_orderline_insert;
DROP TRIGGER IF EXISTS trg_orderline_delete;
DROP TRIGGER IF EXISTS trg_product_price_update;

DELIMITER $$

CREATE TRIGGER trg_orderline_insert
AFTER INSERT ON Orderline
FOR EACH ROW
BEGIN
    UPDATE mv_ProductBuyers
    SET customers =
    (
        SELECT IFNULL(
            GROUP_CONCAT(
                DISTINCT CONCAT(c.id, ' ', c.firstName, ' ', c.lastName)
                ORDER BY c.id
                SEPARATOR ', '
            ),
            ''
        )
        FROM Orderline ol
        JOIN `Order` o ON ol.order_id = o.id
        JOIN Customer c ON o.customer_id = c.id
        WHERE ol.product_id = NEW.product_id
    )
    WHERE productID = NEW.product_id;
END$$

CREATE TRIGGER trg_orderline_delete
AFTER DELETE ON Orderline
FOR EACH ROW
BEGIN
    UPDATE mv_ProductBuyers
    SET customers =
    (
        SELECT IFNULL(
            GROUP_CONCAT(
                DISTINCT CONCAT(c.id, ' ', c.firstName, ' ', c.lastName)
                ORDER BY c.id
                SEPARATOR ', '
            ),
            ''
        )
        FROM Orderline ol
        JOIN `Order` o ON ol.order_id = o.id
        JOIN Customer c ON o.customer_id = c.id
        WHERE ol.product_id = OLD.product_id
    )
    WHERE productID = OLD.product_id;
END$$

CREATE TRIGGER trg_product_price_update
AFTER UPDATE ON Product
FOR EACH ROW
BEGIN
    IF OLD.currentPrice <> NEW.currentPrice THEN
        INSERT INTO PriceHistory (oldPrice, newPrice, product_id)
        VALUES (OLD.currentPrice, NEW.currentPrice, NEW.id);
    END IF;
END$$

DELIMITER ;
EOF

chown "mbennett:mbennett" "/home/mbennett/views.sql"
LogStatus "views.sql generated"

# ----------------------------
# Execute etl.sql as mbennett (unprivileged)
# ----------------------------

NextStep "Executing etl.sql (build + load POS database)"
LogStatus "Running ETL (this can take a bit)"
sudo -u "mbennett" mariadb --local-infile=1 -u "mbennett" -p"${DbPass}" < "/home/mbennett/etl.sql"

touch /root/4-etl-ran
echo "ETL Milestone script executed successfully."
LogStatus "ETL completed"

# ----------------------------
# Execute views.sql as mbennett (unprivileged)
# ----------------------------

NextStep "Executing views.sql (create view, MV table + index, triggers)"
LogStatus "Creating views, MV table, index, and triggers"
sudo -u "mbennett" mariadb -u "mbennett" -p"${DbPass}" < "/home/mbennett/views.sql"

touch /root/5-views-ran
echo "Views/Triggers Milestone script executed successfully."
LogStatus "Views/triggers completed"

NextStep "Deployment complete"
echo "All steps completed successfully."
LogStatus "Deployment complete"
