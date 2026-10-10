package main

import (
	"fmt"
	"os"
	"time"
)

const readingListFile = "readingList.csv"

type readingListEntry struct {
	URL           string    `csv:"url,omitempty"`
	Title         string    `csv:"title,omitempty"`
	Description   string    `csv:"description,omitempty"`
	Image         string    `csv:"image,omitempty"`
	Date          time.Time `csv:"date,omitempty"`
	HackerNewsURL string    `csv:"hnurl,omitempty"`
	Screenshot    string    `csv:"screenshot,omitempty"`
	PDF           string    `csv:"pdf,omitempty"`
	Domain        string    `csv:"domain,omitempty"`
}

func run() error {
	if len(os.Args) == 1 {
		return fmt.Errorf("usage: %s [add|generateSite|serve]", os.Args[0])
	}

	var f func() error

	switch os.Args[1] {
	case "add":
		f = AddRowToCSV
	case "generateSite":
		f = GenerateSite
	case "serve":
		f = Serve
	default:
		return fmt.Errorf("usage: %s [add|generateSite|serve]", os.Args[0])
	}

	return f()
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "%v\n", err)
		os.Exit(1)
	}
}
