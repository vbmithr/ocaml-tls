### Server Name Indication

Some TLS servers might want to provide service for various services,
all on the same port, but with different names. The SNI extension
allows a client to request a specific server name. The server may use
the requested server name to select the X.509 certificate chain which
it presents to the client.

### Configuration interface

A user provides a full certificate chain and a private key
corresponding to the first certificate in the list to OCaml-TLS,
captured by the type `own_cert`.

````
type own_cert = Certificate.certificate list * Nocrypto.Rsa.priv
````

There is one `own_cert` which is the default - to be used if nothing
matches, or if you don't care about SNI at all. A user can also
provide a list of `own_cert` to be chosen from depending on the
indicated server name:

````
  own_certificates  : own_cert option * own_cert list ;
````

### Validation

The configuration of certificates is intertwined with ciphersuites:
each ciphersuite which requires a certificate furthermore depends on
properties of this certificate - RSA and DHE_RSA require the key to be
RSA, RSA requires the X.509v3 extension key_usage to contain
encipherment, DHE_RSA requires key_usage to contain digital_signature.
There must exist at least one certificate with the mentioned
properties for each configured ciphersuite.

Furthermore, to avoid ambiguity, the hostnames of the list of
`own_cert` is checked to be non-overlapping.

### Certificate selection

If the server is configured with only a default certificate, this is
always used.

If the client does not request for a server name, the default
certificate is used.

If the client requests a specific server name:
 - find a strict match
 - find a wildcard match
 - use the default one if present

Only after a certificate is set for the session, the ciphersuite is
selected, depending on the properties of the certificate.
