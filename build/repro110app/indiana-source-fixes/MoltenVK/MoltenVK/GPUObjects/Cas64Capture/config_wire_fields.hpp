// Copyright (c) 2026 MacRunner contributors.
// SPDX-License-Identifier: Apache-2.0
#pragma once
// Field order copied from existing MVKPipeline.mm cache serialization.
// Renamed archive function avoids changing/duplicating product serialization.
#if __has_include(<MoltenVKShaderConverter/SPIRVToMSLConverter.h>)
#include <MoltenVKShaderConverter/SPIRVToMSLConverter.h>
#else
#include "SPIRVToMSLConverter.h"
#endif
namespace SPIRV_CROSS_NAMESPACE {

	template<class Archive>
	void mrCasSerialize(Archive & archive, CompilerMSL::Options& opt) {
		archive(opt.platform,
				opt.msl_version,
				opt.texel_buffer_texture_width,
				opt.r32ui_linear_texture_alignment,
				opt.r32ui_alignment_constant_id,
				opt.swizzle_buffer_index,
				opt.indirect_params_buffer_index,
				opt.shader_output_buffer_index,
#if SPIRV_CROSS_MSL_ACCELERATION_STRUCTURE_DESCRIPTOR_AS_ADDRESS
				opt.acceleration_structure_descriptor_as_address,
					opt.acceleration_structure_address_table_buffer_index,
#if SPIRV_CROSS_MSL_RAY_TRACING_PIPELINE
					opt.ray_tracing_pipeline,
					opt.ray_tracing_max_hit_attribute_size,
					opt.ray_tracing_any_hit_ifb,
					opt.ray_tracing_intersection_ifb,
#endif
#else
				opt.ray_tracing_intersection_buffer_index,
				opt.ray_tracing_callable_buffer_index,
				opt.ray_tracing_recursive_function_buffer_index,
				opt.ray_tracing_recursive_intersection_buffer_index,
				opt.ray_tracing_instance_metadata_buffer_index,
				opt.ray_tracing_acceleration_structure_address_table_buffer_index,
				opt.ray_tracing_stage_depth,
				opt.enable_ray_tracing_pipeline_emulation,
				opt.ray_tracing_raygen_visible,
#endif
				opt.shader_patch_output_buffer_index,
				opt.shader_tess_factor_buffer_index,
				opt.buffer_size_buffer_index,
				opt.view_mask_buffer_index,
				opt.dynamic_offsets_buffer_index,
				opt.shader_input_buffer_index,
				opt.shader_index_buffer_index,
				opt.shader_patch_input_buffer_index,
				opt.draw_id_buffer_index,
				opt.reversed_depth_viewport_buffer_index,
				opt.shader_input_wg_index,
				opt.device_index,
				opt.enable_frag_output_mask,
				opt.additional_fixed_sample_mask,
				opt.enable_point_size_builtin,
				opt.enable_point_size_default,
				opt.default_point_size,
				opt.enable_frag_depth_builtin,
				opt.enable_frag_stencil_ref_builtin,
				opt.disable_rasterization,
				opt.capture_output_to_buffer,
				opt.swizzle_texture_samples,
				opt.tess_domain_origin_lower_left,
				opt.multiview,
				opt.multiview_layered_rendering,
				opt.view_index_from_device_index,
				opt.dispatch_base,
				opt.texture_1D_as_2D,
				opt.emulate_reversed_depth_viewport,
				opt.argument_buffers,
				opt.argument_buffers_tier,
				opt.runtime_array_rich_descriptor,
				opt.enable_base_index_zero,
				opt.pad_fragment_output_components,
				opt.ios_support_base_vertex_instance,
				opt.use_framebuffer_fetch_subpasses,
				opt.invariant_float_math,
				opt.emulate_cube_array,
				opt.enable_decoration_binding,
				opt.texture_buffer_native,
				opt.force_active_argument_buffer_resources,
				opt.pad_argument_buffer_resources,
				opt.force_native_arrays,
				opt.enable_clip_distance_user_varying,
				opt.multi_patch_workgroup,
				opt.raw_buffer_tese_input,
				opt.vertex_for_tessellation,
				opt.arrayed_subpass_input,
				opt.ios_use_simdgroup_functions,
				opt.emulate_subgroups,
				opt.fixed_subgroup_size,
				opt.vertex_index_type,
				opt.force_sample_rate_shading,
				opt.manual_helper_invocation_updates,
				opt.check_discarded_frag_stores,
				opt.sample_dref_lod_array_as_grad,
				opt.readwrite_texture_fences,
				opt.replace_recursive_inputs,
				opt.agx_manual_cube_grad_fixup,
				opt.force_fragment_with_side_effects_execution,
				opt.input_attachment_is_ds_attachment,
				opt.auto_disable_rasterization,
				opt.use_fast_math_pragmas);
	}

	template<class Archive>
	void mrCasSerialize(Archive & archive, MSLShaderInterfaceVariable& si) {
		archive(si.location,
				si.component,
				si.format,
				si.builtin,
				si.vecsize,
				si.rate);
	}

	template<class Archive>
	void mrCasSerialize(Archive & archive, MSLResourceBinding& rb) {
		archive(rb.stage,
				rb.basetype,
				rb.desc_set,
				rb.binding,
				rb.count,
				rb.msl_buffer,
				rb.msl_texture,
				rb.msl_sampler);
	}

	template<class Archive>
	void mrCasSerialize(Archive & archive, MSLConstexprSampler& cs) {
		archive(cs.coord,
				cs.min_filter,
				cs.mag_filter,
				cs.mip_filter,
				cs.s_address,
				cs.t_address,
				cs.r_address,
				cs.compare_func,
				cs.border_color,
				cs.lod_clamp_min,
				cs.lod_clamp_max,
				cs.max_anisotropy,
				cs.planes,
				cs.resolution,
				cs.chroma_filter,
				cs.x_chroma_offset,
				cs.y_chroma_offset,
				cs.swizzle,
				cs.ycbcr_model,
				cs.ycbcr_range,
				cs.bpc,
				cs.compare_enable,
				cs.lod_clamp_enable,
				cs.anisotropy_enable,
				cs.ycbcr_conversion_enable);
	}

}

namespace mvk {

	template<class Archive>
	void mrCasSerialize(Archive & archive, SPIRVWorkgroupSizeDimension& wsd) {
		archive(wsd.size,
				wsd.specializationID,
				wsd.isSpecialized);
	}

	template<class Archive>
	void mrCasSerialize(Archive & archive, SPIRVEntryPoint& ep) {
		archive(ep.mtlFunctionName,
				ep.workgroupSize.width,
				ep.workgroupSize.height,
				ep.workgroupSize.depth,
				ep.fpFastMathFlags);
	}

	template<class Archive>
	void mrCasSerialize(Archive & archive, SPIRVToMSLConversionOptions& opt) {
		archive(opt.mslOptions,
				opt.descriptorSetCount,
				opt.entryPointName,
				opt.entryPointStage,
				opt.rayTracingFunctionHash,
				opt.enableRayTracingIFB,
				opt.enableRayTracingProceduralIFB,
				opt.rayTracingFunctionTableBufferIndex,
				opt.rayTracingIntersectionTableBufferIndex,
				opt.rayTracingCallableTableBufferIndex,
				opt.tessPatchKind,
				opt.numTessControlPoints,
				opt.shouldFlipVertexY,
				opt.shouldFixupClipSpace);
	}

	template<class Archive>
	void mrCasSerialize(Archive & archive, MSLShaderInterfaceVariable& si) {
		archive(si.shaderVar,
				si.binding,
				si.outIsUsedByShader);
	}

	template<class Archive>
	void mrCasSerialize(Archive & archive, MSLResourceBinding& rb) {
		archive(rb.resourceBinding,
				rb.constExprSampler,
				rb.requiresConstExprSampler,
				rb.outIsUsedByShader);
	}

	template<class Archive>
	void mrCasSerialize(Archive & archive, DescriptorBinding& db) {
		archive(db.stage,
				db.descriptorSet,
				db.binding,
				db.index);
	}

	template<class Archive>
	void mrCasSerialize(Archive & archive, SPIRVToMSLConversionConfiguration& cfg) {
		archive(cfg.options,
				cfg.shaderInputs,
				cfg.shaderOutputs,
				cfg.resourceBindings,
				cfg.discreteDescriptorSets,
				cfg.dynamicBufferDescriptors);
	}

}
