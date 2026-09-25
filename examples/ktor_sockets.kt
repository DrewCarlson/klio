// Run with: klio run --feature io.ktor/network examples/ktor_sockets.kt
// ktor-network's sockets, upstream Ktor over klio's host socket layer. A TCP
// server on an ephemeral loopback port accepts a client and the two exchange
// lines and a 64 KiB binary payload through their byte channels; a Unix
// domain socket carries the same line protocol; UDP datagrams arrive with
// their sender's address; and closing a socket completes its job.

import io.ktor.network.selector.SelectorManager
import io.ktor.network.sockets.Datagram
import io.ktor.network.sockets.InetSocketAddress
import io.ktor.network.sockets.UnixSocketAddress
import io.ktor.network.sockets.aSocket
import io.ktor.network.sockets.awaitClosed
import io.ktor.network.sockets.isClosed
import io.ktor.network.sockets.openReadChannel
import io.ktor.network.sockets.openWriteChannel
import io.ktor.network.sockets.port
import io.ktor.utils.io.core.buildPacket
import io.ktor.utils.io.core.writeText
import io.ktor.utils.io.readRemaining
import io.ktor.utils.io.readUTF8Line
import io.ktor.utils.io.writeFully
import io.ktor.utils.io.writeStringUtf8
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.io.readByteArray
import kotlinx.io.readString

fun main() = runBlocking {
    val selector = SelectorManager(Dispatchers.IO)
    val tcp = aSocket(selector).tcp()

    val server = tcp.bind("127.0.0.1", 0)
    println("bound to ${(server.localAddress as InetSocketAddress).hostname}, port assigned: ${server.port > 0}")
    val accepted = async { server.accept() }
    val client = tcp.connect("127.0.0.1", server.port)
    val connection = accepted.await()
    println("remote of the accepted socket is the client: ${connection.remoteAddress == client.localAddress}")

    val toServer = client.openWriteChannel(autoFlush = true)
    val fromClient = connection.openReadChannel()
    val toClient = connection.openWriteChannel(autoFlush = true)
    val fromServer = client.openReadChannel()
    for (word in listOf("alpha", "beta", "gamma")) {
        toServer.writeStringUtf8("$word\n")
        val line = fromClient.readUTF8Line()!!
        toClient.writeStringUtf8(line.uppercase() + "\n")
        println("echoed ${fromServer.readUTF8Line()}")
    }

    val payload = ByteArray(64 * 1024) { (it % 251).toByte() }
    launch {
        toServer.writeFully(payload)
        toServer.flushAndClose()
    }
    val received = fromClient.readRemaining().readByteArray()
    println("binary payload of ${received.size} bytes intact: ${received.contentEquals(payload)}")

    connection.close()
    client.close()
    client.awaitClosed()
    connection.awaitClosed()
    println("both ends closed: ${client.isClosed && connection.isClosed}")
    server.close()

    val path = "/tmp/klio-ktor-sockets-example.sock"
    kotlinx.io.files.SystemFileSystem.delete(kotlinx.io.files.Path(path), mustExist = false)
    val unixServer = tcp.bind(UnixSocketAddress(path))
    val unixAccepted = async { unixServer.accept() }
    val unixClient = tcp.connect(UnixSocketAddress(path))
    val unixConnection = unixAccepted.await()
    unixClient.openWriteChannel(autoFlush = true).writeStringUtf8("over a unix socket\n")
    println("unix: ${unixConnection.openReadChannel().readUTF8Line()}")
    unixClient.close()
    unixConnection.close()
    unixServer.close()
    kotlinx.io.files.SystemFileSystem.delete(kotlinx.io.files.Path(path), mustExist = false)

    val udp = aSocket(selector).udp()
    val first = udp.bind(InetSocketAddress("127.0.0.1", 0))
    val second = udp.bind(InetSocketAddress("127.0.0.1", 0))
    first.send(Datagram(buildPacket { writeText("ping") }, second.localAddress))
    val datagram = second.receive()
    println("udp: ${datagram.packet.readString()} from the first socket: ${datagram.address == first.localAddress}")
    second.send(Datagram(buildPacket { writeText("pong") }, datagram.address))
    println("udp: ${first.receive().packet.readString()}")
    first.close()
    second.close()

    selector.close()
}
