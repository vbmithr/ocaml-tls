open Packet
open Core
open Cstruct

let (<+>) = Utils.Cs.(<+>)

let assemble_protocol_version_int buf version =
  let major, minor = pair_of_tls_version version in
  set_uint8 buf 0 major;
  set_uint8 buf 1 minor

let assemble_protocol_version version =
  let buf = create 2 in
  assemble_protocol_version_int buf version;
  buf

let assemble_any_protocol_version version =
  let buf = create 2 in
  let major, minor = pair_of_tls_any_version version in
  set_uint8 buf 0 major ;
  set_uint8 buf 1 minor ;
  buf

let assemble_hdr version (content_type, payload) =
  let buf = create 5 in
  set_uint8 buf 0 (content_type_to_int content_type);
  assemble_protocol_version_int (shift buf 1) version;
  BE.set_uint16 buf 3 (len payload);
  buf <+> payload

type len = One | Two | Three

let assemble_list ?force lenb f elements =
  let length body =
    match lenb with
    | One   ->
       let l = create 1 in
       set_uint8 l 0 (len body) ;
       l
    | Two   ->
       let l = create 2 in
       BE.set_uint16 l 0 (len body) ;
       l
    | Three ->
       let l = create 3 in
       set_uint24_len l (len body) ;
       l
  in
  let b es = Utils.Cs.appends (List.map f es) in
  let full es =
    let body = b es in
    length body <+> body
  in
  match force with
  | None   -> (match elements with
               | []   -> create 0
               | eles -> full eles)
  | Some _ -> full elements

let assemble_certificate c =
  let length = len c in
  let buf = create 3 in
  set_uint24_len buf length;
  buf <+> c

let assemble_certificates cs =
  assemble_list ~force:true Three assemble_certificate cs

let assemble_compression_method m =
  let buf = create 1 in
  set_uint8 buf 0 (compression_method_to_int m);
  buf

let assemble_compression_methods ms =
  assemble_list ~force:true One assemble_compression_method ms

let assemble_any_ciphersuite c =
  let buf = create 2 in
  BE.set_uint16 buf 0 (any_ciphersuite_to_int c);
  buf

let assemble_any_ciphersuites cs =
  assemble_list ~force:true Two assemble_any_ciphersuite cs

let assemble_ciphersuite c =
  let acs = Ciphersuite.ciphersuite_to_any_ciphersuite c in
  assemble_any_ciphersuite acs

let assemble_hostname host =
  (* 8 bit hostname type; 16 bit length; value *)
  let vallength = String.length host in
  let buf = create 3 in
  set_uint8 buf 0 0; (* type, only 0 registered *)
  BE.set_uint16 buf 1 vallength;
  buf <+> (of_string host)

let assemble_hostnames hosts =
  assemble_list Two assemble_hostname hosts

let assemble_hash_signature (h, s) =
  let buf = create 2 in
  set_uint8 buf 0 (hash_algorithm_to_int h);
  set_uint8 buf 1 (signature_algorithm_type_to_int s);
  buf

let assemble_signature_algorithms s =
  assemble_list Two assemble_hash_signature s

let assemble_named_curve nc =
  let buf = create 2 in
  BE.set_uint16 buf 0 (named_curve_type_to_int nc);
  buf

let assemble_elliptic_curves curves =
  assemble_list Two assemble_named_curve curves

let assemble_ec_point_format f =
  let buf = create 1 in
  set_uint8 buf 0 (ec_point_format_to_int f) ;
  buf

let assemble_ec_point_formats formats =
  assemble_list One assemble_ec_point_format formats

let assemble_extension e =
  let pay, typ = match e with
    | EllipticCurves curves ->
       (assemble_elliptic_curves curves, ELLIPTIC_CURVES)
    | ECPointFormats formats ->
       (assemble_ec_point_formats formats, EC_POINT_FORMATS)
    | SecureRenegotiation x ->
       let buf = create 1 in
       set_uint8 buf 0 (len x);
       (buf <+> x, RENEGOTIATION_INFO)
    | Hostname (Some name) ->
       (assemble_hostnames [name], SERVER_NAME)
    | Hostname None ->
       (create 0, SERVER_NAME)
    | Padding x ->
       let buf = create x in
       for i = 0 to pred x do
         set_uint8 buf i 0
       done;
       (buf, PADDING)
    | SignatureAlgorithms s ->
       (assemble_signature_algorithms s, SIGNATURE_ALGORITHMS)
  in
  let buf = create 4 in
  BE.set_uint16 buf 0 (extension_type_to_int typ);
  BE.set_uint16 buf 2 (Cstruct.len pay);
  buf <+> pay

let assemble_extensions es =
  assemble_list Two assemble_extension es

let assemble_client_hello (cl : client_hello) : Cstruct.t =
  let v = assemble_any_protocol_version cl.version in
  let sid =
    let buf = create 1 in
    match cl.sessionid with
    | None   -> set_uint8 buf 0 0; buf
    | Some s -> set_uint8 buf 0 (len s); buf <+> s
  in
  let css = assemble_any_ciphersuites cl.ciphersuites in
  (* compression methods, completely useless *)
  let cms = assemble_compression_methods [NULL] in
  let bbuf = v <+> cl.random <+> sid <+> css <+> cms in
  (* some widely deployed firewalls drop ClientHello messages which are
     > 256 and < 511 byte, insert PADDING extension for these *)
  (* from draft-agl-tls-padding-03:
   As an example, consider a client that wishes to avoid sending a
   ClientHello with a record size between 256 and 511 bytes (inclusive).
   This case is considered because at least one TLS implementation is
   known to hang the connection when such a ClientHello record is
   received.

   After building a ClientHello as normal, the client can add four to
   the length (to account for the "msg_type" and "length" fields of the
   handshake protocol) and test whether the resulting length falls into
   that range.  If it does, a padding extension can be added in order to
   push the length to (at least) 512 bytes. *)
  let extensions = assemble_extensions cl.extensions in
  let extrapadding =
    let buflen = len bbuf + len extensions + 4 in
    if buflen >= 256 && buflen <= 511 then
      match len extensions with
        | 0 -> (* need to construct a 2 byte extension length as well *)
           let p = assemble_extension (Padding (506 - buflen)) in
           let le = create 2 in
           BE.set_uint16 le 0 (len p + 4);
           le <+> p
        | _ ->
           let l = 508 - buflen in
           let p = assemble_extension (Padding l) in
           BE.set_uint16 extensions 0 (len extensions + l + 4);
           p
    else
      create 0
  in
  bbuf <+> extensions <+> extrapadding

let assemble_server_hello (sh : server_hello) : Cstruct.t =
  let v = assemble_protocol_version sh.version in
  let sid =
    let buf = create 1 in
    match sh.sessionid with
     | None   -> set_uint8 buf 0 0; buf
     | Some s -> set_uint8 buf 0 (len s); buf <+> s
  in
  let cs = assemble_ciphersuite sh.ciphersuites in
  (* useless compression method *)
  let cm = assemble_compression_method NULL in
  let extensions = assemble_extensions sh.extensions in
  let bbuf = v <+> sh.random <+> sid <+> cs <+> cm in
  bbuf <+> extensions

let assemble_dh_parameters p =
  let plen, glen, yslen = (len p.dh_p, len p.dh_g, len p.dh_Ys) in
  let buf = create (2 + 2 + 2 + plen + glen + yslen) in
  BE.set_uint16  buf  0 plen;
  blit p.dh_p  0 buf  2 plen;
  BE.set_uint16  buf (2 + plen) glen;
  blit p.dh_g  0 buf (4 + plen) glen;
  BE.set_uint16  buf (4 + plen + glen) yslen;
  blit p.dh_Ys 0 buf (6 + plen + glen) yslen;
  buf

let assemble_digitally_signed signature =
  let lenbuf = create 2 in
  BE.set_uint16 lenbuf 0 (len signature);
  lenbuf <+> signature

let assemble_digitally_signed_1_2 hashalgo sigalgo signature =
  (assemble_hash_signature (hashalgo, sigalgo)) <+>
    (assemble_digitally_signed signature)

let assemble_client_key_exchange kex =
  let len = len kex in
  let buf = create (len + 2) in
  BE.set_uint16 buf 0 len;
  blit kex 0 buf 2 len;
  buf

let assemble_handshake hs =
  let (payload, payload_type) =
    match hs with
    | ClientHello ch -> (assemble_client_hello ch, CLIENT_HELLO)
    | ServerHello sh -> (assemble_server_hello sh, SERVER_HELLO)
    | Certificate cs -> (assemble_certificates cs, CERTIFICATE)
    | ServerKeyExchange kex -> (kex, SERVER_KEY_EXCHANGE)
    | ClientKeyExchange kex -> (assemble_client_key_exchange kex, CLIENT_KEY_EXCHANGE)
    | ServerHelloDone -> (create 0, SERVER_HELLO_DONE)
    | HelloRequest -> (create 0, HELLO_REQUEST)
    | Finished fs -> (fs, FINISHED)
  in
  let pay_len = len payload in
  let buf = create 4 in
  set_uint8 buf 0 (handshake_type_to_int payload_type);
  set_uint24_len (shift buf 1) pay_len;
  buf <+> payload

let assemble_alert ?level typ =
  let buf = create 2 in
  set_uint8 buf 1 (alert_type_to_int typ);
  (match level with
   | None -> set_uint8 buf 0 (alert_level_to_int Packet.FATAL)
   | Some x -> set_uint8 buf 0 (alert_level_to_int x));
  buf

let assemble_change_cipher_spec =
  let ccs = create 1 in
  set_uint8 ccs 0 1;
  ccs
