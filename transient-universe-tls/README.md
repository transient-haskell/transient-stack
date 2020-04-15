# transient-universe-tls
Secure communications for transient-universe. 

`initTLS` must be called before using any communication. Then any connection with other nodes is atempted to be secure. It is necessary a certificate and a key for the node at the folder where it is executed.  Certificate verification from calling nodes is disabled in this version, so encription of messages among nodes, and not verification is the goal initially.

upon initTLS has been called,  any `connect`  will try to establish a secure connection or will fail.

Connection from web nodes accept `https` requests. If a connection is secure, socket communications are encripted too.

In order to generate a self-signed certificate for testing, try the following:

     openssl genrsa -out key.pem 2048
     openssl req -new -key key.pem -out certificate.csr
     openssl x509 -req -in certificate.csr -signkey key.pem -out certificate.pem
