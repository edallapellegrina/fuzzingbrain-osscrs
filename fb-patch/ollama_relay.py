import socket, threading

def forward(src, dst):
    """
    Copy data from one socket to another until the connection closes.
    
    """
    try:
        while True:
            data = src.recv(4096)
            if not data:
                break
            dst.sendall(data)
    except:
        pass
    finally:
        try: src.close()
        except: pass
        try: dst.close()
        except: pass

def handle(client):
    """
    Handle one client connection.
    For each incoming client:
      - Connect to the local service on 127.0.0.1:11434 (Ollama).
      - Start two forwarding threads so traffic flows both ways.
    """
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.connect(('127.0.0.1', 11434))
    # Forward client -> server
    threading.Thread(target=forward, args=(client, server), daemon=True).start()
    # Forward server -> client
    threading.Thread(target=forward, args=(server, client), daemon=True).start()

listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
# Listen on all interfaces on port 11435
listener.bind(('0.0.0.0', 11435))
listener.listen(50)
print("Relay listening on 0.0.0.0:11435 → 127.0.0.1:11434", flush=True)
while True:
    client, _ = listener.accept()
    # Handle each client in its own thread so multiple clients can be served concurrently
    threading.Thread(target=handle, args=(client,), daemon=True).start()