ENABLE_HTTPS :: false;

#load "websocket.jai";
#load "urlencode.jai";

#if OS == .WINDOWS #load "windows.jai";
#if OS == .LINUX   #load "linux.jai";

// the main entry point is http_listen, which is defined in linux.jai and windows.jai




// todo: this method of looping through middlewares is slow @perf
middlewares: [..]Middleware;
fallback_handler: (*Request)->();

Middleware :: struct {
  method: METHOD;
  path: string;
  cb: (*Request)->();
}

get  :: (path: string, cb: (*Request)->()) {array_add(*middlewares, .{method=.GET , cb=cb, path=normalize_path(path)}); }
post :: (path: string, cb: (*Request)->()) {array_add(*middlewares, .{method=.POST, cb=cb, path=normalize_path(path)}); }
any  :: (path: string, cb: (*Request)->()) {array_add(*middlewares, .{method=.ANY , cb=cb, path=normalize_path(path)}); }

fallback :: (cb: (*Request)->()) {fallback_handler = cb; }




send_html :: (request: *Request, html: string, status_code: u16 = 200, content_type: string = "text/html", content_encoding: string = "", headers: []string = .[]) {
  // todo: status_code 404 is responding with 404 OK; lol
  
  headers_builder: String_Builder;
  init_string_builder(*headers_builder);

  if content_encoding {
    print_to_builder(*headers_builder, "\r\nContent-Encoding: %", content_encoding);
  }
  
  for header : headers {
    print_to_builder(*headers_builder, "\r\n%", header);
  }

  headers_str := builder_to_string(*headers_builder);

  http_response := tprint("HTTP/1.1 % OK\r\nContent-Length: %\r\nContent-Type: %; charset=UTF-8%\r\n\r\n%", status_code, html.count, content_type, headers_str, html);

  print("[DEBUG] send_html response: \n%\n", tprint("HTTP/1.1 % OK\r\nContent-Length: %\r\nContent-Type: %; charset=UTF-8%\r\n\r", status_code, html.count, content_type, headers_str));

  bytes_sent := mysocket_write(request.socket, http_response);
  print("bytes_sent: %\n", bytes_sent);
  request.response_sent = true;
}

send_json :: (request: *Request, json: string) {
  http_response := tprint("HTTP/1.1 200 OK\r\nContent-Length: %\r\nContent-Type: application/json\r\n\r\n%", json.count, json);
  mysocket_write(request.socket, http_response);
  request.response_sent = true;
}

send_file :: (request: *Request, raw_filename: string) {
  filename := normalize_filename(raw_filename);

  print("sending file: %\n", filename);

  file_cache_record, success := file_cache_get_or_create(filename);
  if !success {
    print("[ERROR] failed to send file: %\n", filename);
    return;
  }

  // for very small files, it's possible that brotli encoding is longer than the raw content.
  // in that case the brotli api will return the brotli encoding as ""
  // and so we will return the raw content instead, even though the client accepts br encoding
  are_we_returning_br := false;//does_request_accept_encoding(request, "br") && file_cache_record.brotli != "";

  content := ifx are_we_returning_br then file_cache_record.brotli else file_cache_record.rawcontent;
  content_encoding := ifx are_we_returning_br then "br" else "";
  content_type := extension2contenttype(filename);
  print("successfully sending file\n");
  send_html(request, content, content_type=content_type, content_encoding=content_encoding);
}

send_redirect :: (request: *Request, redirect_to: string, status := 307, headers: []string = .[]) {
  headers_builder: String_Builder;
  init_string_builder(*headers_builder);
  for header : headers {
    print_to_builder(*headers_builder, "\r\n%", header);
  }
  headers_str := builder_to_string(*headers_builder);

  http_response := tprint("HTTP/1.1 % Temporary Redirect\r\nLocation: %\r\nContent-Length: 0%\r\n\r\n", status, redirect_to, headers_str);
  print("response: %\n", http_response);
  mysocket_write(request.socket, http_response);
  request.response_sent = true;
}


SetCookie :: struct {
  key       : string;
  value     : string;
  expires   : string;
  domain    : string;
  path      : string;
  same_site : string;
  secure    : bool;
  http_only : bool;
}


Request :: struct {
  #as socket      : MySocket;

  raw             : string; // entire raw http request
  body            : string; // pointer into raw
  path            : string; // pointer into raw

  content_length  : u32;
  method          : METHOD;
  websocket_key   : string;
  accept_encoding : string;

  params          : Table(string, string);
  query           : Table(string, string);
  headers         : Table(string, string);
  form_data       : Table(string, string);
  cookies         : Table(string, string);

  response_sent   : bool;
  err             : bool;

  #if OS == .LINUX {
    buffercursor  : u32;
    startofline   : u32;
  }

  get_param :: (request: *Request, name: string) -> string {
    val, found := table_find(*request.params, name);
    if !found return "";
    return val;
  }

  get_query :: (request: *Request, name: string) -> string {
    val, found := table_find(*request.query, name);
    if !found return "";
    return val;
  }

  get_header :: (request: *Request, name: string) -> string {
    val, found := table_find(*request.headers, name);
    if !found return "";
    return val;
  }

  get_formdata :: (request: *Request, name: string) -> string {
    val, found := table_find(*request.form_data, name);
    if !found return "";
    return val;
  }

  get_cookie :: (request: *Request, name: string) -> string {
    val, found := table_find(*request.cookies, name);
    if !found return "";
    return val;
  }
}
operator == :: inline (a: Request, b: Request) -> bool {return a.socket == b.socket; }

does_request_accept_encoding :: (request: *Request, encoding: string) -> bool {
  if !request.accept_encoding return false;
  for encoding: split(request.accept_encoding, ",") {
    if trim(encoding, " ") == encoding return true;
  }
  return false;
}

handle_request :: (request: *Request) {

  contains_prams :: (s: string) -> bool {
    return contains(s, ":");
  }

  is_path_match :: (a: string, b: string) -> bool {
    if !contains_prams(a) return a == b;

    parts_a := split(a, "/");
    parts_b := split(b, "/");
    if parts_a.count != parts_b.count return false;

    for parts_a {
      part_a := parts_a[it_index];
      part_b := parts_b[it_index];
      if !contains_prams(part_a) {
        if part_a != part_b return false;
      }
    }

    return true;
  }

  parse_query_params :: (query_str: string) -> Table(string, string) {
    query_params: Table(string, string);

    key_builder: String_Builder;
    init_string_builder(*key_builder);
    value_builder: String_Builder;
    init_string_builder(*value_builder);

    ParseState :: enum u8 {KEY; VALUE;}

    state := ParseState.KEY;

    for i : 0..query_str.count-1 {
      if query_str[i] == {
        case #char "&";
          if state == .KEY {
            // we encountered a loose key without a value, so we just set it to "true", i.e. /page?flag&foo
            table_add(*query_params, builder_to_string(*key_builder), "true");
          } else {
            table_add(*query_params, builder_to_string(*key_builder), builder_to_string(*value_builder));
          }
          state = .KEY;
        case #char "=";
          state = .VALUE;
        case;
          char := ascii(query_str[i]);
          if state == .KEY {
            print_to_builder(*key_builder, char);
          } else {
            print_to_builder(*value_builder, char);
          }
      }
    }

    if state == .VALUE {
      key := builder_to_string(*key_builder);
      value := builder_to_string(*value_builder);

      if value.count > 0 {
        table_add(*query_params, key, value);
      } else {
        // we encountered a loose key without a value, so we just set it to "true", i.e. /page?flag&foo
        table_add(*query_params, key, "true");
      }
    }

    return query_params;
  }

  parse_path_query_params :: (path: string) -> string, Table(string, string) {
    path_parts := split(path, "?");
    path_str := path_parts[0];

    assert(path_parts.count > 0);

    if path_parts.count == 1 {
      // no query params
      empty_query_params: Table(string, string);
      return path_str, empty_query_params;
    }

    query_str := path_parts[1];

    if query_str.count == 0 {
      // no query params
      empty_query_params: Table(string, string);
      return path_str, empty_query_params;
    }

    query_params := parse_query_params(query_str);

    return path_str, query_params;
  }

  path_normal := normalize_path(request.path);

  path_normal, request.query = parse_path_query_params(path_normal);
  
  cookie_header := Request.get_header(request, "Cookie");
  if cookie_header {
    for cookie_str : split(cookie_header, ";") {
      cookie_kv := split(cookie_str, "=");
      if cookie_kv.count < 2 {
        print("[ERROR] Invalid cookie header: %\n", cookie_header);
        break;
      }
      table_add(*request.cookies, trim(cookie_kv[0]), trim(cookie_kv[1]));
    }
  }

  content_type := Request.get_header(request, "Content-Type");
  if content_type == "application/x-www-form-urlencoded" {
    decoded_body := url_decode(request.body);
    // print("form urlencoded: %\n", request.body);
    // print("decoded: %\n", decoded_body);
    request.form_data = parse_query_params(decoded_body);
  }

  if request.websocket_key {
    if table_find_pointer(*websocket_servers, path_normal) {
      websocket_handle_request(request);
    } else {
      // todo: received a websocket request for a path we're not listening to. maybe some kind of notification, send a proper decline response?
    }
  }

  // let the user's middleware handle the request!
  for middleware: middlewares {

    if request.response_sent then break; // once a middleware handles the request, we stop. this is first because webhook could've handled it already

    if middleware.method != .ANY && middleware.method != request.method then continue;
    // if middleware.path != "*" && middleware.path != request.path then continue;
    if middleware.path != "*" && !is_path_match(middleware.path, path_normal) then continue;

    table_reset(*request.params); // maybe this should happen somewhere else?
    middleware_contains_params := contains_prams(middleware.path);
    if middleware_contains_params {
      middleware_path_split := split(middleware.path, "/");
      request_path_split := split(path_normal, "/");
      for middleware_path_split {
        if !contains_prams(it) continue;
        param_name := middleware_path_split[it_index];
        param_name.data += 1;
        param_name.count -= 1;
        // array_add(request.params, request_path_split[it_index]);
        // request.params[param_name] = request_path_split[it_index];
        table_add(*request.params, param_name, request_path_split[it_index]);
        // request.params[param_name] = request_path_split[it_index];
      }
    }

    middleware.cb(request);
  }

  // if none of the middleware responded to this request, 404
  if !request.response_sent {
    if fallback_handler {
      fallback_handler(request);
    } else {
      send_html(request, tprint("<pre>Cannot % %</pre>", request.method, request.path), status_code=404);
    }
  }
}


cwd: string;
the_static_folder_to_serve: string;
static :: (folder: string) {
  assert(folder.count > 0, "folder to serve can't be an empty string");
  assert(the_static_folder_to_serve.count == 0, "you can't currently static serve more than 1 folder");

  cwd = copy_string(get_working_directory());
  the_static_folder_to_serve = folder;

  get("*", (request: *Request) {;

    // if the path ends wht a / then we consider it a folder, and we'll add index.html to the end of the path to load that.
    path: string;
    if ends_with(request.path, "/") {
      path = join(cwd, "/", the_static_folder_to_serve, request.path, "index.html",, temp);
    } else {
      path = join(cwd, "/", the_static_folder_to_serve, request.path,, temp);
    }

    send_file(request, path);
  });
}




// when we cache a file, we store both the raw content and also the brotli compressed version of it
File_Cache_Record :: struct {rawcontent: string; brotli: string; }
file_cache: Table(string, File_Cache_Record);

file_cache_get_or_create :: (filename: string) -> File_Cache_Record, bool {

  #if false && OS != .WINDOWS { // don't actually cache files on windows. for better development experience
    record, found := table_find(*file_cache, filename);
    if found then return record, true;
  }

  filetext, success := read_entire_file(filename);
  if !success return .{}, false;


  // just incase filename is in temporary storage
  // we have to leak a copy of it here to store in the table that won't turn to garbage
  filename_allocated := copy_string(filename);
  file_cache_record := table_set(*file_cache, filename_allocated, .{});
  file_cache_record.rawcontent = filetext;

  content_type := extension2contenttype(filename);
  is_filecontent_text := find_index_from_left("content_type", "text/") == 0;

  #import,dir "modules/brotli";
  compressed := ifx is_filecontent_text then brotli_compress_text(filetext) else brotli_compress(filetext);
  file_cache_record.brotli = compressed;

  return file_cache_record, true;
}






METHOD :: enum u8 {ANY; GET; POST; PUT; DELETE;}
to_METHOD :: (str: string) -> METHOD {
  if str == {
    case "GET";     return .GET;
    case "POST";    return .POST;
    case "PUT";     return .PUT;
    case "DELETE";  return .DELETE;
    case;           return .ANY;
  }
}



extension2contenttype :: (filename: string) -> string {
  index_of_dot := find_index_from_right(filename, ".");
  if index_of_dot == -1 return "text/html";

  extension: string;
  extension.data = filename.data + index_of_dot;
  extension.count = filename.count - index_of_dot;

  if extension == {
    case ".css";  return "text/css";
    case ".js";   return "text/javascript";
    case ".mps";  return "audio/mpeg";
    case ".png";  return "image/png";
    case ".webm"; return "video/webm";
    case ".webp"; return "image/webp";
    case ".gif";  return "image/gif";
    case ".ico";  return "image/x-icon";
    case ".jpg";  return "image/jpeg";
    case ".jpeg"; return "image/jpeg";
    case ".ini";  return "text/plain";
    case ".txt";  return "text/plain";
  }

  return "text/html";
}


normalize_path :: (path: string) -> string { return trim(path, "/"); }

normalize_filename :: (raw_filename: string) -> string {
  filename := raw_filename;

  { // strip questionmark from filename if it exists ex: main.js?293849203
    questionmark_location_in_filename := find_index_from_left(filename, #char "?");
    if questionmark_location_in_filename != -1 {
      filename.count = questionmark_location_in_filename;
    }
  }

  { // replace %xx with xx conveted to a hex byte
    start_index := 0;
    while true {
      percent_location_in_filename := find_index_from_left(filename, #char "%", start_index);
      percent_escape_exists := percent_location_in_filename != -1;
      if !percent_escape_exists break;
      // todo check that there's actually 2 hex chars after the percent
      // ^ this probably can currently crash the server
      // todo make sure it's valid hex? not sure how this should be handled if it's not? probably just ignored?
      hex_chars := substr(filename, percent_location_in_filename + 1, 2);
      string_byte := hex_chars_to_byte(hex_chars);

      filename.data[percent_location_in_filename] = string_byte;
      copy_starting_from := percent_location_in_filename + 1 + 2;
      memcpy(filename.data + percent_location_in_filename + 1, filename.data + copy_starting_from, filename.count-copy_starting_from);
      filename.count -= 2;

      start_index = percent_location_in_filename + 1;
    }
  }

  return filename;
}

hex_char_to_int :: (char: u8) -> u8 {
  if char >= #char "a" return (char - #char "a" + 0xA);
  if char >= #char "A" return (char - #char "A" + 0xA);
  if char >= #char "0" return (char - #char "0");
  return 1;
}
hex_chars_to_byte :: (chars: string) -> u8 {
  assert(chars.count == 2);
  return hex_char_to_int(chars[0]) * 16 + hex_char_to_int(chars[1]);
}







mysocket_read :: (socket: Socket, buffer: *u8, bufferlen: s32) -> s64 {

  #if OS == .LINUX && ENABLE_HTTPS
    if ssl_is_socket_ssl(socket) // perf hash table lookup
      return ssl_read(socket, buffer, xx bufferlen);

  return recv(socket, buffer, xx bufferlen, 0);
}

mysocket_write :: (socket: Socket, buffer: string) -> s64 {

  #if OS == .LINUX && ENABLE_HTTPS
    if ssl_is_socket_ssl(socket) // perf hash table lookup
      return ssl_write(socket, buffer.data, xx buffer.count);
  
  print("[mysocket_write] send buffer: %\n", buffer.count);

  total_bytes_sent := 0;
  while total_bytes_sent < buffer.count {
    bytes_sent := send(socket, buffer.data + total_bytes_sent, xx buffer.count, 0);
    if bytes_sent == -1 {
      err := errno();
      if err == {
        case EWOULDBLOCK;
          // the socket is non-blocking, keep retrying
          continue;
        
        case;
          // some other error occurred
          print("[mysocket_write] failed due to errno %\n", err);
          return -1;
      }
      print("[mysocket_write] ERROR");
    }
    total_bytes_sent += bytes_sent;
    print("[mysocket_write] sent % bytes so far...\n", total_bytes_sent);
  }
  print("[mysocket_write] completed, sent total of % bytes.\n", total_bytes_sent);
  return total_bytes_sent;
}


#import "String";
#import "POSIX";


#scope_file

ascii :: (num: u8) -> string #expand {
    // must be a macro or *num gets invalidated after return
    str : string = ---;
    str.count = 1;
    str.data  = *num;
    return str;
}