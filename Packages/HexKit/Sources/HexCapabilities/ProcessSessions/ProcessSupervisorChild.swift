import Darwin

struct ProcessSupervisorChild {
  let pid: pid_t
  let input: Int32
  let output: Int32
  let error: Int32
}
