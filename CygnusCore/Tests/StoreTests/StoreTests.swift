import Testing
import GRDB
@testable import CygnusStore

@Suite struct StoreTests {
    // Proves the GRDB seam: open, migrate, insert, read. The real
    // interval-versioned schema replaces this in E1.
    @Test func inMemoryDatabaseRoundTrips() throws {
        let db = try GraphDatabase.inMemory()
        try db.write { db in
            try db.execute(sql: "CREATE TABLE probe (id INTEGER PRIMARY KEY, name TEXT)")
            try db.execute(sql: "INSERT INTO probe (name) VALUES (?)", arguments: ["cygnus"])
        }
        let name = try db.read { db in
            try String.fetchOne(db, sql: "SELECT name FROM probe WHERE id = 1")
        }
        #expect(name == "cygnus")
    }
}
