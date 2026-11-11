package com.demomdl.chameleon

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Build
import android.os.ParcelUuid
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeout
import java.util.ArrayDeque
import java.util.UUID
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

@SuppressLint("MissingPermission")
class ChameleonBle(private val context: Context) {

    companion object {
        val NUS: UUID = UUID.fromString("6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
        val RX: UUID = UUID.fromString("6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
        val TX: UUID = UUID.fromString("6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
        val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }

    var onLog: ((String) -> Unit)? = null
    var onConnectionChange: ((Boolean) -> Unit)? = null
    @Volatile var isConnected = false
        private set

    private val adapter: BluetoothAdapter?
        get() = (context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter

    private var gatt: BluetoothGatt? = null
    private var rxChar: BluetoothGattCharacteristic? = null
    private var txChar: BluetoothGattCharacteristic? = null
    private var scanner: BluetoothLeScanner? = null
    private val buffer = FrameBuffer()
    private var mtuPayload = 20

    private var connectCont: CancellableContinuation<Unit>? = null
    private var responseCont: CancellableContinuation<Response>? = null

    private val writeQueue = ArrayDeque<ByteArray>()
    private var writing = false

    private fun log(s: String) = onLog?.invoke(s)

    suspend fun connect(timeoutMs: Long = 15000) {
        val ad = adapter ?: throw IllegalStateException("Bluetooth unavailable")
        if (!ad.isEnabled) throw IllegalStateException("Bluetooth is off")
        if (isConnected) return
        scanner = ad.bluetoothLeScanner ?: throw IllegalStateException("No BLE scanner")
        log("Scanning for NUS service…")
        withTimeout(timeoutMs) {
            suspendCancellableCoroutine { cont: CancellableContinuation<Unit> ->
                connectCont = cont
                val filters = listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(NUS)).build())
                val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
                scanner?.startScan(filters, settings, scanCallback)
                cont.invokeOnCancellation { runCatching { scanner?.stopScan(scanCallback) } }
            }
        }
    }

    fun disconnect() { runCatching { gatt?.disconnect() } }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            scanner?.stopScan(this)
            log("Found device (RSSI ${result.rssi}). Connecting…")
            gatt = result.device.connectGatt(context, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
        }
        override fun onScanFailed(errorCode: Int) {
            log("Scan failed: $errorCode")
            connectCont?.resumeWithException(IllegalStateException("scan failed $errorCode"))
            connectCont = null
        }
    }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> { log("Connected. Negotiating MTU…"); g.requestMtu(247) }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    isConnected = false; onConnectionChange?.invoke(false)
                    rxChar = null; txChar = null; writeQueue.clear(); writing = false
                    connectCont?.resumeWithException(IllegalStateException("disconnected")); connectCont = null
                    responseCont?.resumeWithException(IllegalStateException("disconnected")); responseCont = null
                    log("Disconnected.")
                }
            }
        }

        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
            mtuPayload = if (status == BluetoothGatt.GATT_SUCCESS) (mtu - 3) else 20
            g.discoverServices()
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            val svc = g.getService(NUS)
            if (svc == null) { fail("Nordic UART Service not found — toggle Bluetooth off/on."); return }
            rxChar = svc.getCharacteristic(RX)
            val t = svc.getCharacteristic(TX)
            txChar = t
            if (rxChar == null || t == null) { fail("NUS characteristics not found."); return }
            g.setCharacteristicNotification(t, true)
            val cccd = t.getDescriptor(CCCD)
            if (cccd == null) { ready(); return }
            if (Build.VERSION.SDK_INT >= 33) {
                g.writeDescriptor(cccd, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
            } else {
                @Suppress("DEPRECATION") run {
                    cccd.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                    g.writeDescriptor(cccd)
                }
            }
        }

        override fun onDescriptorWrite(g: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            if (descriptor.uuid == CCCD) ready()
        }

        override fun onCharacteristicWrite(g: BluetoothGatt, ch: BluetoothGattCharacteristic, status: Int) {
            if (ch.uuid == RX) writeNext()
        }

        @Deprecated("Deprecated in Java")
        override fun onCharacteristicChanged(g: BluetoothGatt, ch: BluetoothGattCharacteristic) {
            @Suppress("DEPRECATION")
            handleNotify(ch.uuid, ch.value ?: ByteArray(0))
        }

        override fun onCharacteristicChanged(g: BluetoothGatt, ch: BluetoothGattCharacteristic, value: ByteArray) {
            handleNotify(ch.uuid, value)
        }
    }

    private fun fail(msg: String) {
        connectCont?.resumeWithException(IllegalStateException(msg)); connectCont = null
    }

    private fun ready() {
        isConnected = true; onConnectionChange?.invoke(true)
        log("Ready.")
        connectCont?.resume(Unit); connectCont = null
    }

    private fun handleNotify(uuid: UUID, value: ByteArray) {
        if (uuid != TX) return
        buffer.append(value)
        var r = buffer.next()
        while (r != null) {
            val resp = r
            log("← cmd ${resp.cmd}  status 0x%04X (%s)  %s".format(resp.status, Status.label(resp.status), resp.data.hexSpaced()))
            responseCont?.let { c -> responseCont = null; c.resume(resp) }
            r = buffer.next()
        }
    }

    suspend fun send(cmd: Int, data: ByteArray = ByteArray(0), timeoutMs: Long = 5000): Response {
        val g = gatt ?: throw IllegalStateException("not connected")
        if (!isConnected || rxChar == null) throw IllegalStateException("not connected")
        val frame = Proto.build(cmd, data)
        log("→ [$cmd] ${frame.hexSpaced()}")
        buffer.reset()
        return withTimeout(timeoutMs) {
            suspendCancellableCoroutine { cont: CancellableContinuation<Response> ->
                responseCont = cont
                enqueueFrame(g, frame)
            }
        }
    }

    private fun enqueueFrame(g: BluetoothGatt, frame: ByteArray) {
        val chunk = maxOf(20, mtuPayload)
        var i = 0
        while (i < frame.size) {
            val end = minOf(i + chunk, frame.size)
            writeQueue.add(frame.copyOfRange(i, end))
            i = end
        }
        if (!writing) writeNext()
    }

    private fun writeNext() {
        val g = gatt ?: return
        val r = rxChar ?: return
        val next = writeQueue.poll()
        if (next == null) { writing = false; return }
        writing = true
        if (Build.VERSION.SDK_INT >= 33) {
            g.writeCharacteristic(r, next, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)
        } else {
            @Suppress("DEPRECATION") run {
                r.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                r.value = next
                g.writeCharacteristic(r)
            }
        }
    }
}
