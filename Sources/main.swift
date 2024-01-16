//
//  main.swift
//  QuicTool
//
//  Created by Andrew Paxson on 2024-01-14.
//

import Foundation
import Network

func createMessage(version: UInt8, messageType: UInt8, message: String) -> Data {
    let messageData = message.data(using: .utf8) ?? Data()
    let length = UInt32(messageData.count)

    var data = Data()
    data.append(version)
    data.append(messageType)

    // Convert length to 4 bytes and append (big-endian format)
    let bigEndianLength = length.bigEndian
    data.append(contentsOf: withUnsafeBytes(of: bigEndianLength) { Array($0) })

    // Append 2 bytes of padding for 8-byte alignment
    data.append(Data(repeating: 0, count: 2))

    // Add Message Data.
    data.append(messageData)
    return data
}

let queue = DispatchQueue(label: "quic", qos: .userInteractive)

// Create Inital Options for the tunnel.
// This is using an insecure connection as this operation is meant to be local network.
let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(integerLiteral: 4567))
let options =  NWProtocolQUIC.Options(alpn: ["demo"])
sec_protocol_options_set_verify_block(options.securityProtocolOptions, { (sec_protocol_metadata, sec_trust, sec_protocol_verify_complete) in
    sec_protocol_verify_complete(true)
}, queue)
let parameters = NWParameters(quic: options)

// Create a new multiplexed connection
let descriptor = NWMultiplexGroup(to: endpoint)
let group = NWConnectionGroup(with: descriptor, using: parameters)
var mainConn: NWConnection? = nil

// Here we are establishing a state handler for when the connection to the
// the server is neogiated and "ready". Once its ready we want to open a new
// stream using the group with the options set.
//
// This is the main location of the issue we are seeing where the stream is
// established and the data is sent but never updated.
group.stateUpdateHandler = { newState in
    print("group state: \(newState)")
    switch newState {

    // Once the tunnel is established, create a new stream with bidirectional parameters.
    case .ready:
        print("Connected using QUIC!")


        // I assume I have to create a new set of options to
        // define the stream type.
        let options =  NWProtocolQUIC.Options(alpn: ["demo"])
        options.direction = .unidirectional
        mainConn = group.extract()! // force unwrap

        mainConn?.stateUpdateHandler = { state in
                print("Main Connection State: \(state)")
            switch state {
            case .ready:

                // Once the connection is ready, lets send some sweet data sauce.
                let version: UInt8 = 1
                let messageType: UInt8 = 1
                let message = "hello, I am from the multiplex group ready."
                let messageData = createMessage(version: version, messageType: messageType, message: message)

                mainConn?.send(content: messageData, isComplete: true, completion: .contentProcessed({ sendError in
                    if let error = sendError {
                        print("There was an error sending data: \(error)")
                    } else {
                        print("Data was sent successfully from Main Connection.")
                    }
                }))

            default:
                break
            }
        }
        // Don't forget to start the connection.
        mainConn?.start(queue: queue)
    default:
        break
    }
}


// Receive new incoming streams initiated by the remote endpoint
group.newConnectionHandler = { conn in
    print("New Connection: \(conn)")

  // Set state update handler on incoming stream
    conn.stateUpdateHandler = { newState in
      print("newState: \(newState) for \(conn)")
      switch newState {
      case .ready:
          let version: UInt8 = 1
          let messageType: UInt8 = 2 // Different Message Type for Remote initiated stream for debugging.
          let message = "hello, I am from the new stream from the remote"
          let messageData = createMessage(version: version, messageType: messageType, message: message)
          print("Remote stream send: \(messageData)")
          // Once the connection is ready send some delicious data sauce.
          conn.send(content: messageData, completion: .contentProcessed({ sendError in
              if let error = sendError {
                  print("There was an error sending data: \(error)")
              } else {
                  print("Data was sent successfully.")
              }
          }))

      default:
          break
      }
  }
  // Start the incoming stream
    conn.start(queue: queue)
}

// Start the group with callback queue
group.start(queue: queue)

print("running....")
while true {
    switch mainConn?.state {
    case .ready:
        // Once the connection is ready, lets send some sweet data sauce.
        let version: UInt8 = 1
        let messageType: UInt8 = 1
        let message = "hello, im from the main loop"
        let messageData = createMessage(version: version, messageType: messageType, message: message)
        print("Local Stream Send: \(messageData)")

        mainConn?.send(content: messageData, isComplete: true, completion: .contentProcessed({ sendError in
            if let error = sendError {
                print("There was an error sending data: \(error)")
            }
        }))
        sleep(1)
    default:
        continue
    }
}

