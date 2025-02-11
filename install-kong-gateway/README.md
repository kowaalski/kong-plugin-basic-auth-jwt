# Installing Kong Gateway on EKS using Helm Charts

This guide explains how to install Kong Gateway on an Amazon EKS cluster using Helm charts.

## Prerequisites

Before proceeding, ensure you have:
- An Amazon EKS cluster up and running.
- Helm installed on your local machine.
- `kubectl` configured to interact with your EKS cluster.
- A PostgreSQL database already installed in your EKS cluster (optional, see below).

## Installation Steps

### Step 1: Add the Kong Helm Repository

First, add the Kong Helm repository and update your local Helm chart repository list:

```sh
helm repo add kong https://charts.konghq.com
helm repo update
```

### Step 2: Create a values.yaml file

Create a `values.yaml` file with the following configuration:

```yaml
admin:
  enabled: true
  http:
    enabled: true
  type: ClusterIP

env:
  log_level: debug
  database: postgres  # Uses PostgreSQL as the database
  pg_database: kong_db
  pg_host: kong-db-host
  pg_password: kong_secret_password
  pg_port: 5432
  pg_user: kong_user
  plugins: "bundled,basic-auth-jwt"

ingressController:
  enabled: false

manager:
  enabled: true
  type: ClusterIP

proxy:
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-proxy-protocol-v2: true
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
    service.beta.kubernetes.io/aws-load-balancer-type: nlb
  config:
    proxy_protocol: true
    real_ip_header: proxy_protocol
    trusted_ips: 0.0.0.0/0
  externalTrafficPolicy: Local
  type: LoadBalancer

plugins:
  configMaps:
  - pluginName: basic-auth-jwt
    name: kong-custom-plugins
    mountPath: /usr/local/share/lua/5.1/kong/plugins
```

**Database Configuration:**
This installation assumes that a PostgreSQL database is already installed in the EKS cluster and accessible via `pg_host`. However, Kong can also be deployed without an external database by setting:

```yaml
env:
  database: "off"  # Disables PostgreSQL usage and stores data in memory
```

When using `database: "off"`, Kong will store its configuration in memory within the pods, meaning that data will not persist if the pods restart.

**Plugin Installation:**
The `basic-auth-jwt` plugin is installed under the `plugins` section in the `values.yaml` file. It is configured using a `ConfigMap` and mounted at `/usr/local/share/lua/5.1/kong/plugins`.

### Step 3: Install Kong Gateway with Helm

Run the following command to install Kong Gateway in the `kong-gateway` namespace using Helm:

```sh
helm install kong-gateway kong/kong -n kong-gateway -f values.yaml
```

### Step 4: Install the Custom Plugin

After installing Kong Gateway, deploy the following ConfigMap to the cluster to install the custom plugin:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kong-custom-plugins
  namespace: kong-gateway
data:
  handler.lua: |
    local cjson   = require "cjson"
    local sha1    = require "resty.sha1"
    local to_hex  = require "resty.string".to_hex
    local jwt     = require "resty.jwt"  -- Using resty.jwt to generate the token

    local plugin = {
      PRIORITY = 1000,
      VERSION  = "1.0.0",
      name     = "basic-auth-jwt",
    }

    function plugin:access(conf)
      -- Read the request body
      ngx.req.read_body()
      local body_data = ngx.req.get_body_data()
      if not body_data then
        return kong.response.exit(400, { message = "Missing request body" })
      end

      local decoded_body = kong.request.get_body()
      local user         = decoded_body.user
      local password     = decoded_body.password

      if not user or not password then
        return kong.response.exit(400, { message = "Missing user or password" })
      end

      -- Remove the suffix "-e1" from the user to obtain the actual consumer name
      local consumer_name = user:gsub("%-e%d+$", "")

      -- Construct the Basic Auth header (for forwarding if needed)
      local auth_header = "Basic " .. ngx.encode_base64(user .. ":" .. password)

      local http   = require "resty.http"
      local client = http.new()

      -- Query the Admin API to get the basic-auth credentials associated with the consumer (using consumer_name)
      local res, err = client:request_uri("http://127.0.0.1:8001/consumers/" .. consumer_name .. "/basic-auth", {
        method  = "GET",
        headers = {
          ["Authorization"] = auth_header,
          ["Content-Type"]  = "application/json"
        }
      })

      if not res then
        return kong.response.exit(500, { message = "Error contacting Kong Admin API for basic-auth" })
      end

      local ok, response = pcall(cjson.decode, res.body)
      if not ok or not response or not response.data or type(response.data) ~= "table" or #response.data == 0 then
        return kong.response.exit(401, { message = "User not found" })
      end

      local valid = false
      local consumer_id = nil
      -- Iterate over the basic-auth credentials to find the one where the username matches the original value (with suffix)
      for i, cred in ipairs(response.data) do
        if cred.username == user and cred.consumer and cred.consumer.id then
          -- Apply salting: concatenate the plain text password with consumer.id
          local salted = password .. cred.consumer.id
          local sha1_inst = sha1:new()
          sha1_inst:update(salted)
          local computed_hash = to_hex(sha1_inst:final())
          if computed_hash == cred.password then
            valid = true
            consumer_id = cred.consumer.id
            break
          end
        end
      end

      if not valid then
        return kong.response.exit(401, { message = "Invalid credentials" })
      end

      -- Once basic-auth credentials are validated, query the Admin API to obtain JWT credentials
      local res_jwt, err_jwt = client:request_uri("http://127.0.0.1:8001/consumers/" .. consumer_name .. "/jwt", {
        method  = "GET",
        headers = {
          ["Authorization"] = auth_header,
          ["Content-Type"]  = "application/json"
        }
      })

      if not res_jwt then
        return kong.response.exit(500, { message = "Error contacting Kong Admin API for JWT" })
      end

      local ok_jwt, response_jwt = pcall(cjson.decode, res_jwt.body)
      if not ok_jwt or not response_jwt or not response_jwt.data or type(response_jwt.data) ~= "table" or #response_jwt.data == 0 then
        return kong.response.exit(401, { message = "User does not have JWT associated" })
      end

      local jwt_found = false
      local token = nil
      -- Iterate over the JWT credentials to find the one where the key matches the original user (with suffix)
      for i, jwt_cred in ipairs(response_jwt.data) do
        if jwt_cred.key == user then
          -- Generate a JWT token using the credential's secret
          token = jwt:sign(
            jwt_cred.secret,
            {
              header = { typ = "JWT", alg = "HS256" },
              payload = {
                iss = jwt_cred.key,
                sub = consumer_id,
                exp = ngx.time() + 3600  -- Token valid for 1 hour
              }
            }
          )
          jwt_found = true
          break
        end
      end

      if not jwt_found then
        return kong.response.exit(401, { message = "User does not have JWT associated" })
      end

      -- If JWT is found, return the token as a response
      return kong.response.exit(200, { token = token })
    end

    return plugin
  init.lua: |
    return require("basic-auth-jwt.handler")
  schema.lua: |
    return {
      name = "basic-auth-jwt",
      fields = {
        { config = {
            type = "record",
            fields = {}
          }
        }
      }
    }
```

Apply the ConfigMap:

```sh
kubectl apply -f configmap.yaml -n kong-gateway
```

Then, refresh the `kong-gateway` deployment to ensure the plugin is loaded:

```sh
kubectl rollout restart deployment kong-gateway -n kong-gateway
```

### Step 5: Verify the Installation

Check if the Kong pods are running:

```sh
kubectl get pods -n kong-gateway
```

Check the created services:

```sh
kubectl get svc -n kong-gateway
```

### Step 6: Access Kong Gateway

- **Admin API**: Available at the `ClusterIP` service for internal access.
- **Proxy**: Exposed using an AWS Network Load Balancer (NLB).

### Conclusion

This setup configures Kong Gateway with PostgreSQL as the database, a debug log level, and a custom plugin `basic-auth-jwt`. The proxy service is exposed via an NLB for external access.

If an external database is not available, Kong can be configured to run in `declarative mode` by disabling PostgreSQL, allowing it to store its configuration in memory.

Once Kong Gateway is installed, the custom plugin can be installed using a `ConfigMap`, followed by restarting the Kong deployment to apply the changes.

You can now configure Kong routes and services as per your needs!
