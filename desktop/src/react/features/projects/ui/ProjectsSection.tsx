import { FormEvent, useState } from "react";

import type { ProjectDTO } from "../../workspace/model/useWorkspaceStore";

interface ProjectsSectionProps {
	projects: ProjectDTO[];
	selectedProjectId: string | null;
	loading: boolean;
	creating: boolean;
	onCreateProject: (input: { name?: string; path: string }) => void;
	onSelectProject: (id: string) => void;
	onToggleFavorite: (id: string, isFavorite: boolean) => void;
}

export const ProjectsSection = ({
	projects,
	selectedProjectId,
	loading,
	creating,
	onCreateProject,
	onSelectProject,
	onToggleFavorite,
}: ProjectsSectionProps): JSX.Element => {
	const [name, setName] = useState("");
	const [path, setPath] = useState("");

	const submit = (event: FormEvent) => {
		event.preventDefault();

		const trimmedPath = path.trim();
		if (!trimmedPath) {
			return;
		}

		onCreateProject({
			name: name.trim().length > 0 ? name.trim() : undefined,
			path: trimmedPath,
		});

		setName("");
		setPath("");
	};

	return (
		<section className="panel">
			<header className="panel-header">
				<h2>Projects</h2>
				<span className="panel-subtitle">Project list</span>
			</header>

			<form className="project-form" onSubmit={submit}>
				<label className="label" htmlFor="project-name">
					Name (optional)
				</label>
				<input
					id="project-name"
					onChange={(event) => {
						setName(event.target.value);
					}}
					placeholder="Project name"
					value={name}
				/>
				<label className="label" htmlFor="project-path">
					Absolute path
				</label>
				<input
					id="project-path"
					onChange={(event) => {
						setPath(event.target.value);
					}}
					placeholder="/path/to/project"
					value={path}
				/>
				<button disabled={creating} type="submit">
					{creating ? "Creating project..." : "Create project"}
				</button>
			</form>

			<div className="separator" />

			{loading ? (
				<p className="small-muted">Loading project list...</p>
			) : (
				<ul className="project-list">
					{projects.length === 0 ? (
						<li className="empty-state">No projects found.</li>
					) : (
						projects.map((project) => (
							<li
								aria-label={`Select ${project.name} project`}
								className={`item ${selectedProjectId === project.id ? "active" : ""}`}
								key={project.id}
								onClick={() => {
									onSelectProject(project.id);
								}}
								onKeyDown={(event) => {
									if (event.key === "Enter" || event.key === " ") {
										event.preventDefault();
										onSelectProject(project.id);
									}
								}}
								role="button"
								tabIndex={0}
							>
								<span className="item-main">
									<span>{project.name}</span>
									<span className="small-muted">{project.path}</span>
									{selectedProjectId === project.id ? (
										<span className="small-muted">(Selected)</span>
									) : null}
								</span>
								<button
									aria-label={
										project.isFavorite
											? "Remove from favorites"
											: "Add to favorites"
									}
									className="icon-button"
									onClick={(event) => {
										event.stopPropagation();
										onToggleFavorite(project.id, !project.isFavorite);
									}}
									type="button"
								>
									{project.isFavorite ? "★" : "☆"}
								</button>
							</li>
						))
					)}
				</ul>
			)}
		</section>
	);
};
