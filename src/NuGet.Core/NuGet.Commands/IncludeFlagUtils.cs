using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using NuGet.DependencyResolver;
using NuGet.LibraryModel;
using NuGet.ProjectModel;

namespace NuGet.Commands
{
    internal static class IncludeFlagUtils
    {
        internal static Dictionary<string, LibraryIncludeType> FlattenDependencyTypes(
            RestoreTargetGraph targetGraph,
            PackageSpec spec)
        {
            var result2 = new Dictionary<string, LibraryIncludeType>(StringComparer.OrdinalIgnoreCase);
            var result = new Dictionary<string, IncludeFlags>(StringComparer.OrdinalIgnoreCase);

            // Walk dependencies
            FlattenDependencyTypesUnified(targetGraph, result);

            // Convert to LibraryIncludeType
            foreach (var pair in result)
            {
                result2.Add(pair.Key, GetFlagType(pair.Value));
            }

            // Override flags for direct dependencies
            var directDependencies = spec.Dependencies.ToList();

            // Add dependencies defined under the framework node
            var specFramework = spec.GetTargetFramework(targetGraph.Framework);
            if (specFramework != null && specFramework.Dependencies != null)
            {
                directDependencies.AddRange(specFramework.Dependencies);
            }

            // Override the flags for direct dependencies. This lets the 
            // user take control when needed.
            foreach (var dependency in directDependencies)
            {
                if (result2.ContainsKey(dependency.Name))
                {
                    result2[dependency.Name] = dependency.IncludeType;
                }
                else
                {
                    result2.Add(dependency.Name, dependency.IncludeType);
                }
            }

            return result2;
        }

        private static void FlattenDependencyTypesUnified(
            RestoreTargetGraph targetGraph,
            Dictionary<string, IncludeFlags> result)
        {
            var nodeQueue = new Queue<Node>(1);
            Node node = null;

            var unifiedNodes = new Dictionary<string, GraphItem<RemoteResolveResult>>(StringComparer.OrdinalIgnoreCase);

            // Create a look up table of id -> library
            // This should contain only packages and projects. If there is a project with the 
            // same name as a package, use the project.
            // Projects take precedence over packages here to match the resolver behavior.
            foreach (var item in targetGraph.Flattened
                .OrderBy(lib => OrderType(lib)))
            {
                // Include flags only apply to packages and projects
                if (IsPackageOrProject(item) && !unifiedNodes.ContainsKey(item.Key.Name))
                {
                    unifiedNodes.Add(item.Key.Name, item);
                }
            }

            // Queue all direct references
            foreach (var graph in targetGraph.Graphs)
            {
                foreach (var root in graph.InnerNodes)
                {
                    // Walk only the projects and packages
                    GraphItem<RemoteResolveResult> unifiedRoot;
                    if (unifiedNodes.TryGetValue(root.Key.Name, out unifiedRoot))
                    {
                        // Find the initial project -> dependency flags
                        var typeIntersection = GetFlags(GetDependencyType(graph, root));

                        node = new Node(root.Item, typeIntersection);

                        nodeQueue.Enqueue(node);
                    }
                }
            }

            // Walk the graph using BFS
            // During the walk find the intersection of the include type flags.
            // Dependencies can only have less flags the deeper down the graph
            // we move. Using this we can no-op when a node is encountered that
            // has already been assigned at least as many flags as the current
            // node. We can also assume that all dependencies under it are
            // already correct. If the existing node has less flags then the
            // walk must continue and all new flags found combined with the
            // existing ones.
            while (nodeQueue.Count > 0)
            {
                node = nodeQueue.Dequeue();
                var rootId = node.Item.Key.Name;

                // Combine results on the way up
                IncludeFlags currentTypes;
                if (result.TryGetValue(rootId, out currentTypes))
                {
                    if ((node.DependencyType & currentTypes) == node.DependencyType)
                    {
                        // Noop, this is done
                        continue;
                    }

                    result[rootId] = (currentTypes | node.DependencyType);
                }
                else
                {
                    result.Add(rootId, node.DependencyType);
                }

                foreach (var dependency in node.Item.Data.Dependencies)
                {
                    // Any nodes that are not in unifiedNodes are types that should be ignored
                    // We should also ignore dependencies that are excluded
                    GraphItem<RemoteResolveResult> child;
                    if (unifiedNodes.TryGetValue(dependency.Name, out child)
                        && !dependency.SuppressParent.Equals(LibraryIncludeType.All))
                    {
                        IncludeFlags typeIntersection = 
                            (node.DependencyType & GetFlags(dependency.IncludeType)) 
                            & ~GetFlags(dependency.SuppressParent);

                        var childNode = new Node(child, typeIntersection);
                        nodeQueue.Enqueue(childNode);
                    }
                }
            }
        }

        private class Node
        {
            public Node(GraphItem<RemoteResolveResult> item, IncludeFlags dependencyType)
            {
                DependencyType = dependencyType;
                Item = item;
            }

            public IncludeFlags DependencyType { get; }

            public GraphItem<RemoteResolveResult> Item { get; }
        }

        /// <summary>
        /// Find the flags for a node. 
        /// Include - Exclude - ParentExclude
        /// </summary>
        private static LibraryIncludeType GetDependencyType(
            GraphNode<RemoteResolveResult> parent,
            GraphNode<RemoteResolveResult> child)
        {
            var match = parent.Item.Data.Dependencies.FirstOrDefault(dependency =>
                dependency.Name.Equals(child.Key.Name, StringComparison.OrdinalIgnoreCase));

            Debug.Assert(match != null, "The graph contains a dependency that the node does not list");

            var flags = match.IncludeType;

            // Unless the root project is the grand parent here, the suppress flag should be applied directly to the 
            // child since it has no effect on the parent.
            if (parent.OuterNode != null)
            {
                flags = flags.Except(match.SuppressParent);
            }

            return flags;
        }

        private static bool IsPackageOrProject(GraphItem<RemoteResolveResult> item)
        {
            return item.Key.Type == LibraryTypes.Package
                || item.Key.Type == LibraryTypes.Project
                || item.Key.Type == LibraryTypes.ExternalProject;
        }

        /// <summary>
        /// Prefer projects over packages
        /// </summary>
        /// <param name="item"></param>
        /// <returns></returns>
        private static int OrderType(GraphItem<RemoteResolveResult> item)
        {
            switch (item.Key.Type)
            {
                case LibraryTypes.Project:
                    return 0;
                case LibraryTypes.ExternalProject:
                    return 1;
                case LibraryTypes.Package:
                    return 2;
            }

            return 5;
        }

        [Flags]
        private enum IncludeFlags
        {
            None = 0,
            Runtime = 1,
            Compile = 2,
            Build = 4,
            Native = 8,
            ContentFiles = 16,
            All = 31,
            NoContent = 15,
            NoBuildOrContent = 11
        }

        private static IncludeFlags GetFlags(LibraryIncludeType includeType)
        {
            if (LibraryIncludeType.None.Equals(includeType))
            {
                return IncludeFlags.None;
            }

            if (LibraryIncludeType.All.Equals(includeType))
            {
                return IncludeFlags.All;
            }

            if (LibraryIncludeType.Default.Equals(includeType))
            {
                return IncludeFlags.NoContent;
            }

            if (LibraryIncludeType.DefaultSuppress.Equals(includeType))
            {
                return IncludeFlags.Build | IncludeFlags.ContentFiles;
            }

            IncludeFlags result = IncludeFlags.None;

            if (includeType.Keywords.Contains(LibraryIncludeTypeFlag.Runtime))
            {
                result |= IncludeFlags.Runtime;
            }

            if (includeType.Keywords.Contains(LibraryIncludeTypeFlag.Compile))
            {
                result |= IncludeFlags.Compile;
            }

            if (includeType.Keywords.Contains(LibraryIncludeTypeFlag.Build))
            {
                result |= IncludeFlags.Build;
            }

            if (includeType.Keywords.Contains(LibraryIncludeTypeFlag.Native))
            {
                result |= IncludeFlags.Native;
            }

            if (includeType.Keywords.Contains(LibraryIncludeTypeFlag.ContentFiles))
            {
                result |= IncludeFlags.ContentFiles;
            }

            return result;
        }

        private static LibraryIncludeType GetFlagType(IncludeFlags flags)
        {
            if (flags == IncludeFlags.All)
            {
                return LibraryIncludeType.All;
            }

            if (flags == IncludeFlags.None)
            {
                return LibraryIncludeType.None;
            }

            List<LibraryIncludeTypeFlag> toAdd = new List<LibraryIncludeTypeFlag>();

            if (flags.HasFlag(IncludeFlags.Runtime))
            {
                toAdd.Add(LibraryIncludeTypeFlag.Runtime);
            }

            if (flags.HasFlag(IncludeFlags.Compile))
            {
                toAdd.Add(LibraryIncludeTypeFlag.Compile);
            }

            if (flags.HasFlag(IncludeFlags.Build))
            {
                toAdd.Add(LibraryIncludeTypeFlag.Build);
            }

            if (flags.HasFlag(IncludeFlags.Native))
            {
                toAdd.Add(LibraryIncludeTypeFlag.Native);
            }

            if (flags.HasFlag(IncludeFlags.ContentFiles))
            {
                toAdd.Add(LibraryIncludeTypeFlag.ContentFiles);
            }

            return LibraryIncludeType.None.Combine(toAdd, Enumerable.Empty<LibraryIncludeTypeFlag>());
        }
    }
}
