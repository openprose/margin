#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@inline(__always)
func marginPOSIXRead(
    _ descriptor: Int32,
    _ buffer: UnsafeMutableRawPointer,
    _ count: Int
) -> Int {
#if canImport(Darwin)
    Darwin.read(descriptor, buffer, count)
#else
    Glibc.read(descriptor, buffer, count)
#endif
}

@inline(__always)
func marginPOSIXWrite(
    _ descriptor: Int32,
    _ buffer: UnsafeRawPointer,
    _ count: Int
) -> Int {
#if canImport(Darwin)
    Darwin.write(descriptor, buffer, count)
#else
    Glibc.write(descriptor, buffer, count)
#endif
}
