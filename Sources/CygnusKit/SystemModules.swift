import Foundation

// Classification of imported modules. System modules (Apple
// frameworks, language stdlibs, C system headers) are never charted;
// non-system externals (e.g. GRDB) are hidden by default behind the
// "show external modules" toggle. Internal modules — names matching a
// directory in the repository — are always charted.

public enum SystemModules {
    public static let swift: Set<String> = [
        "Foundation", "SwiftUI", "AppKit", "UIKit", "Combine", "Observation",
        "CoreGraphics", "CoreData", "CoreServices", "CoreFoundation", "CryptoKit",
        "Dispatch", "os", "OSLog", "Darwin", "Metal", "MetalKit", "RealityKit",
        "RealityFoundation", "SceneKit", "SpriteKit", "AVFoundation", "AVKit",
        "QuartzCore", "CoreLocation",
        "MapKit", "WebKit", "Network", "Security", "SystemConfiguration", "XCTest",
        "Testing", "SwiftData", "Charts", "WidgetKit", "StoreKit", "CloudKit",
        "UserNotifications", "Photos", "PhotosUI", "Vision", "CoreML",
        "NaturalLanguage", "Speech", "Contacts", "EventKit", "HealthKit", "HomeKit",
        "GameKit", "GameplayKit", "ARKit", "PencilKit", "QuickLook",
        "SafariServices", "MessageUI", "CoreBluetooth", "CoreMotion", "CoreImage",
        "CoreText", "CoreVideo", "CoreMedia", "CoreAudio", "AudioToolbox",
        "VideoToolbox", "ImageIO", "UniformTypeIdentifiers", "Accessibility",
        "LocalAuthentication", "AuthenticationServices", "BackgroundTasks",
        "AppIntents", "TipKit", "PackageDescription", "Swift", "simd",
        "Accelerate", "GroupActivities", "TabularData", "CreateML", "Playgrounds",
        "JavaScriptCore", "CallKit", "PushKit", "Intents", "IntentsUI",
        "CarPlay", "WatchKit", "ClockKit", "WatchConnectivity", "ExternalAccessory",
        "FileProvider", "FinderSync", "ServiceManagement", "IOKit", "DiskArbitration",
    ]

    public static let python: Set<String> = [
        "os", "sys", "re", "json", "math", "typing", "collections", "itertools",
        "functools", "pathlib", "datetime", "time", "subprocess", "logging",
        "unittest", "abc", "io", "random", "string", "threading",
        "multiprocessing", "socket", "struct", "enum", "dataclasses", "argparse",
        "copy", "pickle", "hashlib", "base64", "tempfile", "shutil", "glob",
        "csv", "sqlite3", "urllib", "http", "email", "html", "xml", "asyncio",
        "contextlib", "inspect", "traceback", "warnings", "weakref", "types",
        "operator", "numbers", "decimal", "fractions", "statistics", "array",
        "bisect", "heapq", "queue", "signal", "errno", "stat", "platform",
        "getpass", "textwrap", "unicodedata", "codecs", "locale", "ctypes",
        "importlib", "pkgutil", "site", "sysconfig", "zlib", "gzip", "bz2",
        "lzma", "zipfile", "tarfile", "configparser", "secrets", "uuid",
        "ipaddress", "selectors", "ssl", "socketserver", "pdb", "profile",
        "cProfile", "timeit", "trace", "gc", "atexit", "builtins", "__future__",
    ]

    public static let c: Set<String> = [
        "stdio.h", "stdlib.h", "string.h", "math.h", "time.h", "ctype.h",
        "errno.h", "float.h", "limits.h", "locale.h", "setjmp.h", "signal.h",
        "stdarg.h", "stddef.h", "assert.h", "stdint.h", "stdbool.h",
        "inttypes.h", "complex.h", "fenv.h", "tgmath.h", "wchar.h", "wctype.h",
        "iso646.h", "unistd.h", "fcntl.h", "sys/types.h", "sys/stat.h",
        "sys/time.h", "sys/socket.h", "sys/mman.h", "sys/wait.h", "sys/ioctl.h",
        "netinet/in.h", "arpa/inet.h", "netdb.h", "pthread.h", "semaphore.h",
        "dirent.h", "dlfcn.h", "poll.h", "termios.h", "syslog.h", "pwd.h",
        "grp.h", "regex.h", "glob.h", "libgen.h", "strings.h", "memory.h",
        "malloc.h", "stdatomic.h", "threads.h",
    ]

    /// Is this module node part of an OS / language runtime? Node ids
    /// look like `<lang>:module:<name>`.
    public static func isSystem(nodeID: String, label: String) -> Bool {
        if nodeID.hasPrefix("swift:module:") { return swift.contains(label) }
        if nodeID.hasPrefix("python:module:") {
            return python.contains(label.split(separator: ".").first.map(String.init) ?? label)
        }
        if nodeID.hasPrefix("c:module:") { return c.contains(label) }
        return false
    }
}
