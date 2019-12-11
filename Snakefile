import os
import pandas as pd
from pathlib import Path
import re
from snakemake.utils import validate

configfile: 'config.yaml'
validate(config, 'schemas/config.schema.yaml')

read_metadata = pd.read_table(config['read_metadata']) \
    .set_index('filename', drop=False)
validate(read_metadata, 'schemas/read_metadata.schema.yaml')

localrules: all, bam_fofn, symlink_assembly, cluster_config,
            arrow_aggregate, split_fasta, index_fasta,
            fasta_slice_fofn

rule all:
    input: 'results/arrow/aligned_subread_bams.fofn'

rule index_fasta:
    input: '{filename}.fa'
    output: '{filename}.fa.fai'
    conda: 'envs/samtools.yaml'
    shell: 'samtools faidx {input}'

checkpoint split_fasta:
    input:
        fasta=config['contig_fasta']
    output:
        directory('data/contigs_split')
    params:
        chunk_size=config['splitting']['chunk-size']
    conda: 'envs/racon.yaml'
    shell:
        '''
        mkdir {output}
        rampler split -o {output} {input.fasta} {params.chunk_size}
        '''

def get_fasta_slices(wildcards):
    checkpoint_output = checkpoints.split_fasta.get().output[0]
    fname_pattern = Path(checkpoint_output, '{filename}_{{part}}.fasta'.format(filename=Path(config['contig_fasta']).stem))
    gwc = glob_wildcards(fname_pattern)
    raw_files = expand(str(fname_pattern), part=gwc.part)
    files = sorted(raw_files, key=lambda x: int(re.search(r'\d+', x).group(0)))
    return files

def get_arrow_aggregate_input(wildcards):
    checkpoint_output = checkpoints.split_fasta.get().output[0]
    fname_pattern = Path(checkpoint_output, '{filename}_{{part}}.fasta'.format(filename=Path(config['contig_fasta']).stem))
    gwc = glob_wildcards(fname_pattern)
    return expand('results/arrow/polished_slices/polished_slice_{part}.fa', part=gwc.part)

rule arrow_aggregate:
    '''
    Merge the polished FASTA slices from arrow (gcpp).
    '''
    input:
        get_arrow_aggregate_input
    output:
        'results/arrow/polished_contigs.fa'
    shell:
        'cat {input} > {output}'

rule arrow:
    '''
    Run one iteration of arrow on a slice of the assembly (gcpp).
    '''
    input:
        all_fasta=get_fasta_slices,
        bam='results/arrow/alignment_slices/subread_alignments_slice_{part}.bam'
    output:
        'results/arrow/polished_slices/polished_slice_{part}.fa'
    wildcard_constraints:
        part=r'\d+'
    conda: 'envs/arrow.yaml'
    shell:
        '''
        files=({input.all_fasta})
        slice_fasta=${{files[$(({wildcards.part}))]}}
        gcpp \
            --reference ${{slice_fasta}} \
            --output {output} \
            {input.bam}
        '''

rule arrow_bam_slice:
    '''
    Get a slice of the alignments to use for polishing with arrow.
    '''
    input:
        all_fasta=get_fasta_slices,
        bamfiles='results/arrow/aligned_subread_bams.fofn'
    output:
        bam='results/arrow/alignment_slices/subread_alignments_slice_{part}.bam',
        bai='results/arrow/alignment_slices/subread_alignments_slice_{part}.bam.bai'
    wildcard_constraints:
        run=r'\d+'
    conda: 'envs/samtools.yaml'
    shell:
        '''
        files=({input.all_fasta})
        slice_fasta=${{files[$(({wildcards.part}))]}}
        samtools faidx ${{slice_fasta}}
        regions=$(awk '{{if (NR == 1) {{printf("%s", $1)}} else {{printf(",%s", $1)}}}}' ${{slice_fasta}}.fai)
        samtools merge -b {input.bamfiles} -R "${{regions}}" {output.bam} 
        samtools index {output.bam}
        '''

rule bam_fofn:
    '''
    Create a file of filenames (fofn) of all subreads
    aligned to the assembly.
    '''
    input: expand('results/alignments/{bam_name}_alignments.bam', \
                  bam_name=[Path(x).stem for x in read_metadata.filename[read_metadata.filetype == 'bam']])
    output: 'results/arrow/aligned_subread_bams.fofn'
    shell: 'printf "%s\\n" $(realpath -es {input}) > {output}'

def get_full_bam_path(wildcards):
    '''
    Get the full path to a bam file based on its basename.
    '''
    matches = [re.search(r'^.+{fname}.bam$'.format(fname=wildcards.bam_name), x) \
               for x in read_metadata.filename]
    matches = [x.group(0) for x in matches if x is not None]

    if len(matches) > 1:
        raise WorkflowError('multiple bam files with the name {fname}.bam' \
            .format(fname=wildcards.bam_name))

    return matches[0]

rule pbmm2_align:
    '''
    Align reads with pbmm2, i.e. the PacBio wrapper for minimap2.
    '''
    input:
        reference='reference/{reference}_subread.mmi' \
            .format(reference=Path(config['contig_fasta']).stem),
        query_bam=get_full_bam_path
    output:
        'results/alignments/{bam_name}_alignments.bam'
    threads: 10
    params:
        preset='SUBREAD',
    conda: 'envs/arrow.yaml'
    shell:
        '''
        pbmm2 align \
            --preset {params.preset} \
            --sort \
            -m 4G \
            -j {threads} \
            {input.reference} \
            {input.query_bam} \
            {output}
        '''

rule pbmm2_index:
    '''
    Create a minimap index for the assembly.
    '''
    input: 'reference/{reference}.fasta'
    output: 'reference/{reference}_subread.mmi'
    threads: 20
    params:
        preset='SUBREAD'
    conda: 'envs/arrow.yaml'
    shell:
        '''
        pbmm2 index \
            --num-threads {threads} \
            --preset {params.preset} \
            {input} \
            {output}
        '''

rule symlink_assembly:
    '''
    Symlink the assembly FASTA file to the project directory.
    '''
    input: Path(config['contig_fasta']).absolute()
    output: 'reference/{reference}.fasta' \
        .format(reference=Path(config['contig_fasta']).stem)
    shell:
        '''
        cd reference
        ln -s {input} $(basename {output})
        '''

rule cluster_config:
    '''
    Generate a cluster profile.
    '''
    output: directory( \
        '{home}/.config/snakemake/{profile_name}' \
            .format(home=Path.home(), \
                    profile_name=config['cluster']['profile_name']))
    params:
        url=config['cluster']['cookiecutter_url'],
        profile_name=config['cluster']['profile_name']
    conda: 'envs/cluster_config.yaml'
    shell: 'bash scripts/cluster_config.sh {params.url} {params.profile_name}'
