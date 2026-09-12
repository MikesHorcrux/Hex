import Foundation
import SQLite3

enum SQLiteHeartbeatConnectionValue {
  case integer(Int64)
  case real(Double)
  case text(String)
  case blob(Data)
  case null
}
