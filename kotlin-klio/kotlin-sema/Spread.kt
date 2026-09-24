// The array join code lowered from sema spreads arrays into a vararg with:
// a new array of the parts' kind holding every part's elements in order.

package kotlin

@PublishedApi
internal external fun __klio_arrayConcat(parts: Array<out Any>): Any
