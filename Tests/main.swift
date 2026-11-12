import Foundation

let old = """
{"id":"00000000-0000-0000-0000-000000000001","title":"Manga","fileName":"manga.cbz","format":"zip","addedAt":0,"lastPage":12,"lastOffset":12,"pageCount":100,"bookmarks":[{"id":"00000000-0000-0000-0000-000000000002","page":12,"offset":12,"label":"12","createdAt":0}]}
""".data(using: .utf8)!
let decoder = JSONDecoder()
var book = try decoder.decode(Book.self, from: old)
precondition(book.favorite == nil && book.layoutOverride == nil && book.trimMargins == nil && book.lastPage == 12)
precondition(book.bookmarks.count == 1 && book.bookmarks[0].note == nil)
book.favorite = true
book.layoutOverride = "spread"
book.trimMargins = true
book.bookmarks[0].note = "A note"
let copy = try decoder.decode(Book.self, from: JSONEncoder().encode(book))
precondition(copy.favorite == true && copy.layoutOverride == "spread" && copy.trimMargins == true && copy.lastPage == 12)
precondition(copy.bookmarks[0].note == "A note")
print("Old library and new settings round trip passed")
