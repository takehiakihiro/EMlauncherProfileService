#!/usr/bin/ruby

# PayloadIdentifier: identifies a payload through its lifetime (all versions)
# PayloadType: kind of payload, do not change
# PayloadDisplayName: display name, shown on install and inspection
# PayloadDescription: longer description to go with display name

=begin

NOTES

The use of certificates has been simplified for the sake of providing a
simple example.  We'll just be using a root and ssl certificate.  The ssl
certificate will be used for:
- TLS cert for the profile service
- RA cert for the simplified SCEP service 
- Profile signing cert for profiles generated by the service


FIX UPS

remove more debug logging or make it optional, just like dumping payloads
describe the apple certificate hierarchy for device certificates


=end

require 'webrick'
require 'webrick/https'
include WEBrick

require 'openssl'

require 'set'

# http://plist.rubyforge.org
$:.unshift(File.dirname(__FILE__) + "/plist/lib")
require 'plist'

# http://UUIDTools.rubyforge.org
$:.unshift(File.dirname(__FILE__) + "/uuidtools/lib")
require 'uuidtools'

require 'mysql2'
require 'base64'

# explicitly set this to host ip or name if more than one interface exists
@@address = "secp.example.com"
# SECP service port number.
@@port = 8443
# EMlauncher URL.
@@emlauncher_url = "https://emlauncher.example.com/"
# prefix for profile payload
@@secp_prefix = "com.example"
# Connection information for EMlauncher MySQL Server
@@mysql_connection_info = {:host => 'emlauncher.example.com', :username => 'emlauncher', :password => 'password', :encoding => 'utf8', :database => 'emlauncher'}
# String for Display WebClip Icon title and other
@@emlauncher_title = "EMlauncher"

def local_ip
    # turn off reverse DNS resolution temporarily
    orig, Socket.do_not_reverse_lookup = Socket.do_not_reverse_lookup, true  

    UDPSocket.open do |s|
        s.connect '0.0.0.1', 1
        s.addr.last
    end
ensure
    Socket.do_not_reverse_lookup = orig
end

@@root_cert = nil
@@root_key = nil
@@serial = 100

@@ssl_key = nil
@@ssl_cert = nil
@@ssl_chain = nil

@@ra_key = nil
@@ra_cert = nil

@@issued_first_profile = Set.new

def issue_cert(dn, key, serial, not_before, not_after, extensions, issuer, issuer_key, digest)
    cert = OpenSSL::X509::Certificate.new
    issuer = cert unless issuer
    issuer_key = key unless issuer_key
    cert.version = 2
    cert.serial = serial
    cert.subject = dn
    cert.issuer = issuer.subject
    cert.public_key = key.public_key
    cert.not_before = not_before
    cert.not_after = not_after
    ef = OpenSSL::X509::ExtensionFactory.new
    ef.subject_certificate = cert
    ef.issuer_certificate = issuer
    extensions.each { |oid, value, critical|
        cert.add_extension(ef.create_extension(oid, value, critical))
    }
    cert.sign(issuer_key, digest)
    cert
end


def issueCert(req, validdays)
    req = OpenSSL::X509::Request.new(req)
    cert = issue_cert(req.subject, req.public_key, @@serial, Time.now, Time.now+(86400*validdays), 
        [ ["keyUsage","digitalSignature,keyEncipherment",true] ],
        @@root_cert, @@root_key, OpenSSL::Digest::SHA1.new)
    @@serial += 1
    File.open("serial", "w") { |f| f.write @@serial.to_s }
    cert
end


require 'socket'

def local_ip
  orig, Socket.do_not_reverse_lookup = Socket.do_not_reverse_lookup, true  # turn off reverse DNS resolution temporarily

  UDPSocket.open do |s|
    s.connect '17.244.0.1', 1
    s.addr.last
  end
ensure
  Socket.do_not_reverse_lookup = orig
end



def service_address(request)
    address = "localhost"
    if request.addr.size > 0
        host, port = request.addr[2], request.addr[1]
    end
    "#{@@address}" + ":" + port.to_s
end


=begin
        *** PAYLOAD SECTION ***
=end

def general_payload
    payload = Hash.new
    payload['PayloadVersion'] = 1 # do not modify
    payload['PayloadUUID'] = UUIDTools::UUID.random_create().to_s # should be unique

    # string that show up in UI, customisable
    payload['PayloadOrganization'] = "EMLauncher."
    payload
end


def profile_service_payload(request, challenge)
    payload = general_payload()

    payload['PayloadType'] = "Profile Service" # do not modify
    payload['PayloadIdentifier'] = @@secp_prefix + ".mobileconfig.profile-service"

    # strings that show up in UI, customisable
    payload['PayloadDisplayName'] = "EMLauncher Configuration Service"
    payload['PayloadDescription'] = "Install this profile to enroll for secure access to #{@@emlauncher_title}."

    payload_content = Hash.new
    payload_content['URL'] = "https://" + service_address(request) + "/profile"
    payload_content['DeviceAttributes'] = [
        "UDID", 
        "VERSION",
        "PRODUCT",              # ie. iPhone1,1 or iPod2,1
        "MAC_ADDRESS_EN0",      # WiFi MAC address
        "DEVICE_NAME"           # given device name "iPhone"
=begin
        # Items below are only available on iPhones
        "IMEI",
        "ICCID"
=end
        ];
    if (challenge && !challenge.empty?)
        payload_content['Challenge'] = challenge
    end

    payload['PayloadContent'] = payload_content
    Plist::Emit.dump(payload)
end


def scep_cert_payload(request, purpose, challenge)
    payload = general_payload()

    payload['PayloadIdentifier'] = @@secp_prefix + ".encryption-cert-request"
    payload['PayloadType'] = "com.apple.security.scep" # do not modify

    # strings that show up in UI, customisable
    payload['PayloadDisplayName'] = purpose
    payload['PayloadDescription'] = "Provides device encryption identity"

    payload_content = Hash.new
    payload_content['URL'] = "https://" + service_address(request) + "/scep"
=begin
    # scep instance NOTE: required for MS SCEP servers
    payload_content['Name'] = "" 
=end
    payload_content['Subject'] = [ [ [ "O", @@emlauncher_title ] ], 
        [ [ "CN", purpose + " (" + UUIDTools::UUID.random_create().to_s + ")" ] ] ];
    if (!challenge.empty?)
        payload_content['Challenge'] = challenge
    end
    payload_content['Keysize'] = 1024
    payload_content['Key Type'] = "RSA"
    payload_content['Key Usage'] = 5 # digital signature (1) | key encipherment (4)
    # NOTE: MS SCEP server will only issue signature or encryption, not both

    # SCEP can run over HTTP, as long as the CA cert is verified out of band
    # Below we achieve this by adding the fingerprint to the SCEP payload
    # that the phone downloads over HTTPS during enrollment.
=begin
    # Disabled until the following is fixed: <rdar://problem/7172187> SCEP various fixes
    payload_content['CAFingerprint'] = StringIO.new(OpenSSL::Digest::SHA1.new(@@root_cert.to_der).digest)
=end

    payload['PayloadContent'] = payload_content;
    payload
end


def encryption_cert_payload(request, challenge)
    payload = general_payload()
    
    payload['PayloadIdentifier'] = @@secp_prefix + ".encrypted-profile-service"
    payload['PayloadType'] = "Configuration" # do not modify
  
    # strings that show up in UI, customisable
    payload['PayloadDisplayName'] = "Profile Service Enroll"
    payload['PayloadDescription'] = "Enrolls identity for the encrypted profile service"

    payload['PayloadContent'] = [scep_cert_payload(request, "Profile Service", challenge)];
    Plist::Emit.dump(payload)
end


def webclip_payload_with_uuid(request)

    webclip_payload = general_payload()

    webclip_payload['PayloadIdentifier'] = @@secp_prefix + ".webclip.emlauncher"
    webclip_payload['PayloadType'] = "com.apple.webClip.managed" # do not modify

    # strings that show up in UI, customisable
    webclip_payload['PayloadDisplayName'] = @@emlauncher_title
    webclip_payload['PayloadDescription'] = "Creates a link to the #{@@emlauncher_title} on the home screen"
    
    # allow user to remove webclip
    webclip_payload['IsRemovable'] = true
    
    # the link
    query = HTTPUtils::parse_query(request.query_string)
    print "device_uuid: #{query['device_uuid']}\n"

    webclip_payload['Label'] = @@emlauncher_title
    webclip_payload['URL'] = @@emlauncher_url + "?device_uuid=" + query['device_uuid'];

    if File.exist?("WebClipIcon.png")
        webclip_payload['Icon'] = StringIO.new(File.read("WebClipIcon.png"))
    end

    Plist::Emit.dump([webclip_payload])
end

def webclip_payload(request)

    webclip_payload = general_payload()

    webclip_payload['PayloadIdentifier'] = @@secp_prefix + ".webclip.emlauncher"
    webclip_payload['PayloadType'] = "com.apple.webClip.managed" # do not modify

    # strings that show up in UI, customisable
    webclip_payload['PayloadDisplayName'] = @@emlauncher_title
    webclip_payload['PayloadDescription'] = "Creates a link to the #{@@emlauncher_title} on the home screen"
    
    # allow user to remove webclip
    webclip_payload['IsRemovable'] = true
    
    # the link
    webclip_payload['Label'] = @@emlauncher_title
    webclip_payload['URL'] = @@emlauncher_url

    if File.exist?("WebClipIcon.png")
        webclip_payload['Icon'] = StringIO.new(File.read("WebClipIcon.png"))
    end

    Plist::Emit.dump([webclip_payload])
end


def configuration_payload(request, encrypted_content)
    payload = general_payload()
    payload['PayloadIdentifier'] = @@secp_prefix + ".emlauncher"
    payload['PayloadType'] = "Configuration" # do not modify

    # strings that show up in UI, customisable
    payload['PayloadDisplayName'] = @@emlauncher_title + " Config"
    payload['PayloadDescription'] = "Access to the " + @@emlauncher_title
    payload['PayloadExpirationDate'] = Date.today + 365 # expire today, for demo purposes

    payload['EncryptedPayloadContent'] = StringIO.new(encrypted_content)
    Plist::Emit.dump(payload)
end


def init

    if @@address == "AUTOMATIC"
        @@address = local_ip
        print "*** detected address #{@@address} ***\n"
    end

    ca_cert_ok = false
    ra_cert_ok = false
    ssl_cert_ok = false
    
    begin
        @@root_key = OpenSSL::PKey::RSA.new(File.read("ca_private.pem"))
        @@root_cert = OpenSSL::X509::Certificate.new(File.read("ca_cert.pem"))
        @@serial = File.read("serial").to_i
        ca_cert_ok = true
        @@ra_key = OpenSSL::PKey::RSA.new(File.read("ra_private.pem"))
        @@ra_cert = OpenSSL::X509::Certificate.new(File.read("ra_cert.pem"))
        ra_cert_ok = true
        @@ssl_key = OpenSSL::PKey::RSA.new(File.read("ssl_private.pem"))
        @@ssl_cert = OpenSSL::X509::Certificate.new(File.read("ssl_cert.pem"))
        if File.exist?("ssl_chain.pem")
	    @@ssl_chain = OpenSSL::X509::Certificate.new(File.read("ssl_chain.pem"))
            @@ssl_chain.extensions.each { |e|
                print "chain:***#{e.value}***\n"
            }
        end
        @@ssl_cert.extensions.each { |e| 
            print "***DNS:#{@@address}***\n"
            print "***#{e.value}***\n"
            if "#{e.value}" == "DNS:#{@@address}" then
              ssl_cert_ok = true
              break
            end
            # e.value} == "DNS:#{@@address}" && ssl_cert_ok = true
        }
        if !ssl_cert_ok
            print "*** server address changed; issuing new ssl certificate ***\n"
            print "***DNS:#{@@address}***\n"
            raise
        end
    rescue
        if !ca_cert_ok
        then
            @@root_key = OpenSSL::PKey::RSA.new(1024)
            @@root_cert = issue_cert( OpenSSL::X509::Name.parse(
                "/O=None/CN=EMlauncer Root CA (#{UUIDTools::UUID.random_create().to_s})"),
                @@root_key, 1, Time.now, Time.now+(86400*365), 
                [ ["basicConstraints","CA:TRUE",true],
                ["keyUsage","Digital Signature,keyCertSign,cRLSign",true] ],
                nil, nil, OpenSSL::Digest::SHA1.new)
            @@serial = 100

            File.open("ca_private.pem", "w") { |f| f.write @@root_key.to_pem }
            File.open("ca_cert.pem", "w") { |f| f.write @@root_cert.to_pem }
            File.open("serial", "w") { |f| f.write @@serial.to_s }
        end
        
        if !ra_cert_ok
        then
            @@ra_key = OpenSSL::PKey::RSA.new(1024)
            @@ra_cert = issue_cert( OpenSSL::X509::Name.parse(
                "/O=None/CN=EMLAUNCHER SCEP RA"),
                @@ra_key, @@serial, Time.now, Time.now+(86400*365), 
                [ ["basicConstraints","CA:TRUE",true],
                ["keyUsage","Digital Signature,keyEncipherment",true] ],
                @@root_cert, @@root_key, OpenSSL::Digest::SHA1.new)
            @@serial += 1
            File.open("ra_private.pem", "w") { |f| f.write @@ra_key.to_pem }
            File.open("ra_cert.pem", "w") { |f| f.write @@ra_cert.to_pem }
        end
        
        @@ssl_key = OpenSSL::PKey::RSA.new(1024)
        @@ssl_cert = issue_cert( OpenSSL::X509::Name.parse("/O=None/CN=#{@@emlauncher_title} Profile Service"),
            @@ssl_key, @@serial, Time.now, Time.now+(86400*365), 
            [   
                ["keyUsage","Digital Signature",true] ,
                ["subjectAltName", "DNS:" + @@address, true]
            ],
            @@root_cert, @@root_key, OpenSSL::Digest::SHA1.new)
        @@serial += 1
        File.open("serial", "w") { |f| f.write @@serial.to_s }
        File.open("ssl_private.pem", "w") { |f| f.write @@ssl_key.to_pem }
        File.open("ssl_cert.pem", "w") { |f| f.write @@ssl_cert.to_pem }
    end
end





=begin
*************************************************************************
    
*************************************************************************
=end

init()

if @@ssl_chain != nil
    world = WEBrick::HTTPServer.new(
      :Port            => @@port,
      :DocumentRoot    => Dir::pwd + "/htdocs",
      :SSLEnable       => true,
      :SSLVerifyClient => OpenSSL::SSL::VERIFY_NONE,
      :SSLCertificate  => @@ssl_cert,
      :SSLExtraChainCert => [@@ssl_chain],
      :SSLPrivateKey   => @@ssl_key
    )
else
    world = WEBrick::HTTPServer.new(
      :Port            => @@port,
      :DocumentRoot    => Dir::pwd + "/htdocs",
      :SSLEnable       => true,
      :SSLVerifyClient => OpenSSL::SSL::VERIFY_NONE,
      :SSLCertificate  => @@ssl_cert,
      :SSLPrivateKey   => @@ssl_key
    )
end

world.mount_proc("/") { |req, res|
    res['Content-Type'] = "text/html"
    res.body = <<WELCOME_MESSAGE
    
<style>
body { margin:40px 40px;font-family:Helvetica;}
h1 { font-size:80px; }
p { font-size:60px; }
a { text-decoration:none; }
</style>

<h1 >#{@@emlauncher_title} Profile Service</h1>

<p>If you had to accept the certificate accessing this page, you should
download the <a href="/CA">root certificate</a> and install it so it becomes trusted. 

<p>We are using a self-signed
certificate here, for production it should be issued by a known CA.

<p>After that, go ahead and <a href="/enroll">enroll</a>

WELCOME_MESSAGE

}

world.mount_proc("/CA") { |req, res|
    res['Content-Type'] = "application/x-x509-ca-cert"
    res.body = @@root_cert.to_der
}

world.mount_proc("/enroll") { |req, res|
    HTTPAuth.basic_auth(req, res, "realm") {|user, password|
        user == 'apple' && password == 'apple'
    }

    res['Content-Type'] = "application/x-apple-aspen-config"
    configuration = profile_service_payload(req, "signed-auth-token")
    if @@ssl_chain != nil
      signed_profile = OpenSSL::PKCS7.sign(@@ssl_cert, @@ssl_key, 
              configuration, [@@ssl_chain], OpenSSL::PKCS7::BINARY)
    else
      signed_profile = OpenSSL::PKCS7.sign(@@ssl_cert, @@ssl_key,
              configuration, [], OpenSSL::PKCS7::BINARY)
    end
    res.body = signed_profile.to_der

}

world.mount_proc("/profile") { |req, res|

    # verify CMS blob, but don't check signer certificate
    p7sign = OpenSSL::PKCS7.new(req.body)
    store = OpenSSL::X509::Store.new
    p7sign.verify(nil, store, nil, OpenSSL::PKCS7::NOVERIFY)
    signers = p7sign.signers
    
    # this should be checking whether the signer is a cert we issued
    #
    device_attributes = Plist::parse_xml(p7sign.data)
    device_udid = device_attributes['UDID']
    device_name = device_attributes['DEVICE_NAME']
    device_version = device_attributes['VERSION']
    device_product = device_attributes['PRODUCT']
    print "Device UDID: #{device_udid}\n"
    query = HTTPUtils::parse_query(req.query_string)
    device_uuid = query['device_uuid'];
    print "device_uuid: #{device_uuid}\n"
    print "signers: " + signers[0].issuer.to_s + "\n"
    print "root_cert: " + @@root_cert.subject.to_s + "\n"
    if (signers[0].issuer.to_s == @@root_cert.subject.to_s)
        print "Request from cert with serial #{signers[0].serial}"
            " seen previously: #{@@issued_first_profile.include?(signers[0].serial.to_s)}"
            " (profiles issued to #{@@issued_first_profile.to_a}) \n"
        if (@@issued_first_profile.include?(signers[0].serial.to_s))
          res.set_redirect(WEBrick::HTTPStatus::MovedPermanently, "/enroll")
            print res
        else
          if !device_uuid.nil? && !device_uuid.empty?
            # username, :password, :host, :port, :database, :socket
            client = Mysql2::Client.new(@@mysql_connection_info)
            sql = %{select mail, device_uuid from ios_device_info where device_uuid=?}
            stmt = client.prepare(sql)
            results = stmt.execute(device_uuid)
            results.each do |row|
              puts "--------------------"
              row.each do |key, value|
                puts "#{key} => #{value}"
              end
            end
            if results.count > 0
              sql = %{select device_uuid from ios_device_info where device_uuid!=? and device_udid=?}
              stmt = client.prepare(sql)
              results = stmt.execute(device_uuid, device_udid)
              if results.count > 0
                results.each do |row|
                  puts "--------------------"
                  row.each do |key, value|
                    puts "#{key} => #{value}"
                  end
                end
                sql = %{delete from ios_device_info where device_uuid!=? and device_udid=?}
                stmt = client.prepare(sql)
                results = stmt.execute(device_uuid, device_udid)
              end

              sql = %{select device_udid from ios_device_info where device_uuid=?}
              stmt = client.prepare(sql)
              results = stmt.execute(device_uuid)
              if results.count > 0
                sql = %{update ios_device_info set device_udid=?, device_name=?, device_version=?, device_product=? where device_uuid=?}
                stmt = client.prepare(sql)
                results = stmt.execute(device_udid, device_name, device_version, device_product, device_uuid)
              end
              @@issued_first_profile.add(signers[0].serial.to_s)
              payload = webclip_payload_with_uuid(req)
                        
              #File.open("payload", "w") { |f| f.write payload }
              encrypted_profile = OpenSSL::PKCS7.encrypt(p7sign.certificates,
                  payload, OpenSSL::Cipher::Cipher::new("des-ede3-cbc"), 
                  OpenSSL::PKCS7::BINARY)
              configuration = configuration_payload(req, encrypted_profile.to_der)
	    end
          else
            @@issued_first_profile.add(signers[0].serial.to_s)
            payload = webclip_payload(req)
            encrypted_profile = OpenSSL::PKCS7.encrypt(p7sign.certificates,
                payload, OpenSSL::Cipher::Cipher::new("des-ede3-cbc"),
                OpenSSL::PKCS7::BINARY)
            configuration = configuration_payload(req, encrypted_profile.to_der)
          end
        end
    else
        #File.open("signeddata", "w") { |f| f.write p7sign.data }
        device_attributes = Plist::parse_xml(p7sign.data)
        #print device_attributes
        
=begin
        # Limit issuing of profiles to one device and validate challenge
        if device_attributes['UDID'] == "213cee5cd11778bee2cd1cea624bcc0ab813d235" &&
            device_attributes['CHALLENGE'] == "signed-auth-token"
        else
            print "Device UDID: #{device_attributes['UDID']}\n"
        end
=end
        configuration = encryption_cert_payload(req, "")
    end

    if !configuration || configuration.empty?
        raise "you lose"
    else
		# we're either sending a configuration to enroll the profile service cert
		# or a profile specifically for this device
		res['Content-Type'] = "application/x-apple-aspen-config"
   
        if @@ssl_chain != nil
            signed_profile = OpenSSL::PKCS7.sign(@@ssl_cert, @@ssl_key, 
                configuration, [@@ssl_chain], OpenSSL::PKCS7::BINARY)
        else
            signed_profile = OpenSSL::PKCS7.sign(@@ssl_cert, @@ssl_key,
                configuration, [], OpenSSL::PKCS7::BINARY)
        end
        res.body = signed_profile.to_der
        File.open("profile.der", "w") { |f| f.write signed_profile.to_der }
    end
}

=begin
This is a hacked up SCEP service to simplify the profile service demonstration
but clearly doesn't perform any of the security checks a regular service would
enforce.
=end
world.mount_proc("/scep"){ |req, res|

  print "Query #{req.query_string}\n"
  query = HTTPUtils::parse_query(req.query_string)
  
  if query['operation'] == "GetCACert"
    res['Content-Type'] = "application/x-x509-ca-ra-cert"
    scep_certs = OpenSSL::PKCS7.new()
    scep_certs.type="signed"
    scep_certs.certificates=[@@root_cert, @@ra_cert]
    res.body = scep_certs.to_der
  else 
    if query['operation'] == "GetCACaps"
        res['Content-Type'] = "text/plain"
        res.body = "POSTPKIOperation\nSHA-1\nDES3\n"
    else
      if query['operation'] == "PKIOperation"
        p7sign = OpenSSL::PKCS7.new(req.body)
        store = OpenSSL::X509::Store.new
        p7sign.verify(nil, store, nil, OpenSSL::PKCS7::NOVERIFY)
        signers = p7sign.signers
        p7enc = OpenSSL::PKCS7.new(p7sign.data)
        csr = p7enc.decrypt(@@ra_key, @@ra_cert)
        cert = issueCert(csr, 1)
        degenerate_pkcs7 = OpenSSL::PKCS7.new()
        degenerate_pkcs7.type="signed"
        degenerate_pkcs7.certificates=[cert]
        enc_cert = OpenSSL::PKCS7.encrypt(p7sign.certificates, degenerate_pkcs7.to_der, 
            OpenSSL::Cipher::Cipher::new("des-ede3-cbc"), OpenSSL::PKCS7::BINARY)
        reply = OpenSSL::PKCS7.sign(@@ra_cert, @@ra_key, enc_cert.to_der, [], OpenSSL::PKCS7::BINARY)
        res['Content-Type'] = "application/x-pki-message"
        res.body = reply.to_der
       end
     end
  end
}

trap(:INT) do
  world.shutdown
end

world_t = Thread.new {
  Thread.current.abort_on_exception = true
  world.start
}

world_t.join

