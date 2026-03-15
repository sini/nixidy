{
  lib,
  klib,
  pkgs,
}:
{
  /*
    Downloads a helm chart from a helm registry.

    > This is re-exported directly from [farcaller/nix-kube-generators](https://github.com/farcaller/nix-kube-generators).

    Type:
      downloadHelmChart :: AttrSet -> Derivation
  */
  downloadHelmChart = klib.downloadHelmChart;

  /*
    Templates a helm chart with provided values and creates a derivation
    with the output.

    > This is re-exported directly from [farcaller/nix-kube-generators](https://github.com/farcaller/nix-kube-generators).

    Type:
      buildHelmChart :: AttrSet -> Derivation
  */
  buildHelmChart = klib.buildHelmChart;

  /*
    Templates a helm chart and outputs a JSON array of kubernetes objects.
    Combines helm template + YAML→JSON conversion into a single derivation,
    eliminating the extra fromYAML IFD that would otherwise be needed.

    Type:
      buildHelmChartJSON :: AttrSet -> [AttrSet]
  */
  buildHelmChartJSON =
    {
      name,
      chart,
      namespace ? null,
      values ? { },
      includeCRDs ? true,
      kubeVersion ? "v${pkgs.kubernetes.version}",
      apiVersions ? [ ],
      extraOpts ? [ ],
    }:
    let
      hasNamespace = !builtins.isNull namespace;
      helmNamespaceFlag = if hasNamespace then "--namespace ${namespace}" else "";
      namespaceName = if hasNamespace then "-${namespace}" else "";
    in
    builtins.filter (v: v != null) (
      builtins.fromJSON (
        builtins.readFile (
          pkgs.stdenv.mkDerivation {
            name = "helm-json-${chart}${namespaceName}-${name}";

            passAsFile = [ "helmValues" ];
            helmValues = builtins.toJSON values;
            helmCRDs = if includeCRDs then "--include-crds" else "";
            inherit kubeVersion;

            phases = [ "installPhase" ];
            installPhase = ''
              export HELM_CACHE_HOME="$TMP/.nix-helm-build-cache"

              ${pkgs.kubernetes-helm}/bin/helm template \
              $helmCRDs \
              ${helmNamespaceFlag} \
              --kube-version "$kubeVersion" \
              --values "$helmValuesPath" \
              "${name}" \
              "${chart}" \
              ${builtins.concatStringsSep " " extraOpts} \
              ${builtins.concatStringsSep " " (map (v: "-a ${v}") apiVersions)} \
              | ${pkgs.yq}/bin/yq -Ms '.' > $out
            '';
          }
        )
      )
    );

  /*
    Parse the default values file shipped with the helm chart.

    Type:
      getChartValues :: Derivation -> AttrSet

    Example:
      getChartValues (lib.helm.downloadHelmChart {
          repo = "https://argoproj.github.io/argo-helm/";
          chart = "argo-cd";
          version = "5.51.4";
          chartHash = "sha256-LOEJ5mYaHEA0RztDkgM9DGTA0P5eNd0SzSlwJIgpbWY=";
      })
      => {
        server.replicas = 1;
        controller.replicas = 1;
        # ...
      }
  */
  getChartValues =
    # Derivation containing helm chart. Usually output of [lib.helm.downloadHelmChart](#libhelmdownloadhelmchart).
    chart: lib.head (klib.fromYAML (builtins.readFile "${chart}/values.yaml"));

  /*
    Walk a directory tree and import all `default.nix` to download helm charts.

    The `default.nix` needs to have the following format:

    ```nix title="./charts/kubernetes-csi/csi-driver-nfs/default.nix"
    {
      repo = "https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts";
      chart = "csi-driver-nfs";
      version = "4.7.0";
      chartHash = "sha256-EU2qaZglUU3vxa41l1p/2yBscksIhYMr8kSgH8t0vL8=";
    }
    ```

    Type:
      mkChartAttrs :: Path -> AttrSet

    Example:
      mkChartAttrs ./charts
      => {
        kubernetes-csi = {
          csi-driver-nfs = lib.helm.downloadHelmChart {
            repo = "https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts";
            chart = "csi-driver-nfs";
            version = "4.7.0";
            chartHash = "sha256-EU2qaZglUU3vxa41l1p/2yBscksIhYMr8kSgH8t0vL8=";
          };
        };
      }
  */
  mkChartAttrs =
    # Path to a directory containing the correct directory structure described above.
    dir:
    let
      walkDir =
        prefix: dir:
        let
          contents = builtins.readDir "${prefix}/${dir}";
        in
        if contents ? "default.nix" && contents."default.nix" == "regular" then
          lib.helm.downloadHelmChart (import "${prefix}/${dir}")
        else
          builtins.listToAttrs (
            map (d: {
              inherit (d) name;
              value = walkDir "${prefix}/${dir}" d.name;
            }) (lib.filter (c: c.value == "directory") (lib.attrsToList contents))
          );

      contents = builtins.readDir dir;
    in
    builtins.listToAttrs (
      map (d: {
        inherit (d) name;
        value = walkDir dir d.name;
      }) (lib.filter (c: c.value == "directory") (lib.attrsToList contents))
    );
}
