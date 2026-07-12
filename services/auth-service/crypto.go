package main

import (
	"crypto/rand"
	"math/big"
)

// randomDigits generates a string of n random decimal digits.
func randomDigits(n int) string {
	const digits = "0123456789"
	result := make([]byte, n)
	for i := range result {
		idx, _ := rand.Int(rand.Reader, big.NewInt(int64(len(digits))))
		result[i] = digits[idx.Int64()]
	}
	return string(result)
}
