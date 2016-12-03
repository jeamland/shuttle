import Foundation
import IOKit
import IOKit.hid
import Quartz
import CoreAudio

let ioman = IOHIDManagerCreate(kCFAllocatorDefault,
    IOOptionBits(kIOHIDOptionsTypeNone))
let runloop : CFRunLoop = CFRunLoopGetCurrent()
let devices = [
    kIOHIDVendorIDKey: 0x0b33,
    kIOHIDProductIDKey: 0x0020
] as CFDictionary

let vendorKey = kIOHIDVendorIDKey as CFString
let productKey = kIOHIDProductIDKey as CFString

struct Elements {
    static let Button1 : IOHIDElementCookie = 7
    static let Button2 : IOHIDElementCookie = 8
    static let Button3 : IOHIDElementCookie = 9
    static let Button4 : IOHIDElementCookie = 10
    static let Button5 : IOHIDElementCookie = 11
    static let JogDial : IOHIDElementCookie = 16
    static let ScrollWheel : IOHIDElementCookie = 17
}

let iTunesVolumeUpScript =
    "tell application \"iTunes\"\n" +
    "  set sound volume to sound volume + 1\n" +
    "end tell\n"
let iTunesVolumeDownScript =
    "tell application \"iTunes\"\n" +
    "  set sound volume to sound volume - 1\n" +
    "end tell\n"
let iTunesVolumeUp = NSAppleScript.init(source: iTunesVolumeUpScript)!
let iTunesVolumeDown = NSAppleScript.init(source: iTunesVolumeDownScript)!

var discardWheelEvent : Bool = false
var lastWheelValue : Int = 0

var lastJogValue : Int = 0

let leftOutputName = "Burr-Brown Japan PCM2702"
let rightOutputName = "Built-in Output"
var leftOutputID : AudioDeviceID? = nil
var rightOutputID : AudioDeviceID? = nil

func generateMediaKeyEvent(key: Int32, down: Bool) -> CGEvent {
    let state : Int32 = down ? 0xa00 : 0xb00
    let data1 : Int32 = key << 16 | state

    let event = NSEvent.otherEvent(
        with: NSSystemDefined,
        location: NSPoint(x: 0, y: 0),
        modifierFlags: NSEventModifierFlags(rawValue: UInt(state)),
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        subtype: 8,
        data1: Int(data1),
        data2: -1
    )

    return event!.cgEvent!
}

func tapCallback(proxy: CGEventTapProxy,
              type: CGEventType,
              event: CGEvent,
              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if (event.type == CGEventType.scrollWheel && discardWheelEvent) {
        discardWheelEvent = false
        return nil
    }

    return Unmanaged.passRetained(event)
}

func handleJogValue(value: Int) {
    if (value > 0 && value > lastJogValue) {
        iTunesVolumeUp.executeAndReturnError(nil)
    } else if (value < 0 && value < lastJogValue) {
        iTunesVolumeDown.executeAndReturnError(nil)
    }

    lastJogValue = value
}

func handleWheelValue(value: Int) {
    var key : Int32 = 0

    if (value == 0 && lastWheelValue == 255) {
        key = NX_KEYTYPE_SOUND_UP
    } else if (value == 255 && lastWheelValue == 0) {
        key = NX_KEYTYPE_SOUND_DOWN
    } else if (value > lastWheelValue) {
        key = NX_KEYTYPE_SOUND_UP
    } else {
        key = NX_KEYTYPE_SOUND_DOWN
    }

    generateMediaKeyEvent(key: key, down: true).post(tap:.cgSessionEventTap)
    generateMediaKeyEvent(key: key, down: false).post(tap:.cgSessionEventTap)

    lastWheelValue = value
    discardWheelEvent = true
}

func discoverOutputDevices() {
    var devicesPropertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMaster
    )
    var propertySize : UInt32 = 0

    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
        &devicesPropertyAddress, 0, nil, &propertySize)

    let numberOfDevices = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs : [AudioDeviceID] = []
    for _ in 0 ..< numberOfDevices {
        deviceIDs.append(AudioDeviceID())
    }

    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
        &devicesPropertyAddress, 0, nil, &propertySize, &deviceIDs)

    for id in deviceIDs {
        var name : CFString = "" as CFString
        var propertySize : UInt32 = UInt32(MemoryLayout<CFString>.size)
        var deviceNamePropertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMaster
        )
        AudioObjectGetPropertyData(id, &deviceNamePropertyAddress, 0, nil, &propertySize, &name)
        if (name as String == leftOutputName) {
            print("Left output (\(name)) is \(id)")
            leftOutputID = id
        } else if (name as String == rightOutputName) {
            print("Right output (\(name)) is \(id)")
            rightOutputID = id
        }
    }
}

func setAudioOutput(deviceID: AudioDeviceID?) {
    if (deviceID == nil) {
        return
    }

    var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMaster
    )
    let propertySize : UInt32 = UInt32(MemoryLayout<AudioDeviceID>.size)
    var outputID = deviceID!

    AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),
        &defaultOutputAddress, 0, nil, propertySize, &outputID)
}

guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                  place: .headInsertEventTap,
                                  options: .defaultTap,
                                  eventsOfInterest: UInt64(1 << CGEventType.scrollWheel.rawValue),
                                  callback: tapCallback,
                                  userInfo: nil) else {
    print("failed to create event tap")
    exit(1)
}

// NX_KEYTYPE_PLAY
// NX_KEYTYPE_NEXT
// NX_KEYTYPE_PREVIOUS
// NX_KEYTYPE_SOUND_DOWN
// NX_KEYTYPE_SOUND_UP

var valueCallback : IOHIDValueCallback = {
    (context, result, sender, value) in

    let element = IOHIDValueGetElement(value)
    let cookie = IOHIDElementGetCookie(element)
    let code = IOHIDValueGetIntegerValue(value)

    var event : CGEvent?

    switch cookie {
        case Elements.Button1:
            setAudioOutput(deviceID: leftOutputID)
            event = nil
        case Elements.Button2:
            event = generateMediaKeyEvent(key: NX_KEYTYPE_PREVIOUS, down: code == 1)
        case Elements.Button3:
            event = generateMediaKeyEvent(key: NX_KEYTYPE_PLAY, down: code == 1)
        case Elements.Button4:
            event = generateMediaKeyEvent(key: NX_KEYTYPE_NEXT, down: code == 1)
        case Elements.Button5:
            setAudioOutput(deviceID: rightOutputID)
            event = nil
        case Elements.JogDial:
            handleJogValue(value: code)
            event = nil
        case Elements.ScrollWheel:
            if (code != lastWheelValue) {
                handleWheelValue(value: code)
            }
            event = nil
        default:
            print("Unknown element")
            event = nil
    }

    if (event != nil) {
        event!.post(tap:.cgSessionEventTap)
    }
}

var attachCallback : IOHIDDeviceCallback = {
    (context, result, sender, device) in

    let v = IOHIDDeviceGetProperty(device, vendorKey) as! CFNumber as Int
    let p = IOHIDDeviceGetProperty(device, productKey) as! CFNumber as Int

    IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))

    let elements = IOHIDDeviceCopyMatchingElements(device, nil, 0)!
    for element in (elements as! Array<IOHIDElement>) {
        let cookie = IOHIDElementGetCookie(element)
        if (cookie == Elements.ScrollWheel) {
            var value : IOHIDValue = IOHIDValueCreateWithIntegerValue(nil, element, 0, 0)
            var valueRef = Unmanaged.passRetained(value) as Unmanaged<IOHIDValue>
            IOHIDDeviceGetValue(device, element, &valueRef)
            lastWheelValue = IOHIDValueGetIntegerValue(valueRef.takeUnretainedValue())
        }
    }

    IOHIDDeviceRegisterInputValueCallback(device, valueCallback, nil)

    print(String(format: "attached: vendor %04x device %04x", v, p))

    discoverOutputDevices()
}

var detachCallback : IOHIDDeviceCallback = {
    (context, result, sender, device) in

    let v = IOHIDDeviceGetProperty(device, vendorKey) as! CFNumber as Int
    let p = IOHIDDeviceGetProperty(device, productKey) as! CFNumber as Int

    leftOutputID = nil
    rightOutputID = nil

    print(String(format: "detached: vendor %04x device %04x", v, p))
}

IOHIDManagerSetDeviceMatching(ioman, devices)
IOHIDManagerRegisterDeviceMatchingCallback(ioman, attachCallback, nil)
IOHIDManagerRegisterDeviceRemovalCallback(ioman, detachCallback, nil)

IOHIDManagerScheduleWithRunLoop(ioman, runloop,
    CFRunLoopMode.defaultMode.rawValue)
IOHIDManagerOpen(ioman, IOOptionBits(kIOHIDOptionsTypeNone))

let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

CFRunLoopRun()
