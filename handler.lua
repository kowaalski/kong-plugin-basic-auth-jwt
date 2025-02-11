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
