// dropempty: copy an image to a new reference while removing empty (<=40 byte) layers and stamping
// the Cloud Marketplace service-name annotation.
//
// Why: Google's Marketplace image copier fails with `Manifest references unknown blob(s)` on an empty
// layer (a 29-32 byte gzip of an empty tar), and the app Dockerfile ends with a WORKDIR on an existing
// directory, which produces exactly one. The image content is unchanged; only the layer list, the
// config's diff_ids and the history flags are rewritten.
//
// Usage: dropempty <src-ref> <dst-ref>      (registry auth comes from the docker credential helpers)
// Env:   SERVICE_NAME (default windyflo.endpoints.windyflo-public.cloud.goog)
package main

import (
	"fmt"
	"os"

	"github.com/google/go-containerregistry/pkg/authn"
	"github.com/google/go-containerregistry/pkg/name"
	v1 "github.com/google/go-containerregistry/pkg/v1"
	"github.com/google/go-containerregistry/pkg/v1/empty"
	"github.com/google/go-containerregistry/pkg/v1/mutate"
	"github.com/google/go-containerregistry/pkg/v1/remote"
)

func must(err error) {
	if err != nil {
		panic(err)
	}
}

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: dropempty <src-ref> <dst-ref>")
		os.Exit(2)
	}
	service := os.Getenv("SERVICE_NAME")
	if service == "" {
		service = "windyflo.endpoints.windyflo-public.cloud.goog"
	}
	src, err := name.ParseReference(os.Args[1])
	must(err)
	dst, err := name.ParseReference(os.Args[2])
	must(err)
	auth := remote.WithAuthFromKeychain(authn.DefaultKeychain)

	img, err := remote.Image(src, auth)
	must(err)
	layers, err := img.Layers()
	must(err)
	cf, err := img.ConfigFile()
	must(err)
	cf2 := cf.DeepCopy()

	var keep []v1.Layer
	var diffIDs []v1.Hash
	drop := map[int]bool{}
	for i, l := range layers {
		size, err := l.Size()
		must(err)
		if size <= 40 {
			drop[i] = true
			fmt.Println("dropping layer", i, "size", size)
			continue
		}
		keep = append(keep, l)
		diffIDs = append(diffIDs, cf2.RootFS.DiffIDs[i])
	}
	if len(drop) == 0 {
		fmt.Println("no empty layers; re-publishing unchanged apart from the annotation")
	}
	// Mark the history entry of each dropped layer as empty so history and layers stay consistent.
	k := 0
	for i := range cf2.History {
		if cf2.History[i].EmptyLayer {
			continue
		}
		if drop[k] {
			cf2.History[i].EmptyLayer = true
		}
		k++
	}
	cf2.RootFS.DiffIDs = diffIDs

	out := mutate.MediaType(empty.Image, "application/vnd.oci.image.manifest.v1+json")
	out = mutate.ConfigMediaType(out, "application/vnd.oci.image.config.v1+json")
	out, err = mutate.AppendLayers(out, keep...)
	must(err)
	out, err = mutate.ConfigFile(out, cf2)
	must(err)
	out = mutate.Annotations(out, map[string]string{
		"com.googleapis.cloudmarketplace.product.service.name": "services/" + service,
	}).(v1.Image)

	must(remote.Write(dst, out, auth))
	d, err := out.Digest()
	must(err)
	fmt.Println("NEW DIGEST", d)
}
